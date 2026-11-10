// SPDX-License-Identifier: GPL-2.0
/*
 * Sony IMX241 camera sensor driver (5 MP, RAW10, 2-lane MIPI CSI-2)
 *
 * Written for the front camera of the Samsung Galaxy Book 10.6
 * (SM-W620/SM-W627, ACPI INT347F behind the Intel IPU3 CIO2). The mode
 * register tables were taken from the Windows driver of that tablet
 * (imx241.sys 30.14393.10458.4232, tables for a 26 MHz input clock).
 *
 * Timing (from the tables):
 *   PLL = 26 MHz / 3 * 115 = 996.67 MHz, single PLL mode
 *   MIPI link frequency = PLL / 2 = 498.33 MHz (DDR), 2 lanes
 *   pixel rate = link * 2 * 2 / 10 = 199.33 Mpixel/s
 *   LINE_LENGTH_PCK counts two pixels per unit
 */

#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/module.h>
#include <linux/pm_runtime.h>
#include <linux/regulator/consumer.h>
#include <linux/units.h>

#include <media/v4l2-cci.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-fwnode.h>
#include <media/v4l2-mediabus.h>

#define IMX241_REG_MODEL_ID		CCI_REG16(0x0000)
#define IMX241_MODEL_ID			0x0241

#define IMX241_REG_MODE_SELECT		CCI_REG8(0x0100)
#define IMX241_MODE_STANDBY		0x00
#define IMX241_MODE_STREAMING		0x01

#define IMX241_REG_ORIENTATION		CCI_REG8(0x0101)

#define IMX241_REG_EXPOSURE		CCI_REG16(0x0202)
#define IMX241_EXPOSURE_MIN		1
#define IMX241_EXPOSURE_STEP		1
/* the Windows tables leave 5 lines between exposure and frame length */
#define IMX241_EXPOSURE_OFFSET		5

#define IMX241_REG_ANALOG_GAIN		CCI_REG16(0x0204)
#define IMX241_ANA_GAIN_MIN		0
#define IMX241_ANA_GAIN_MAX		224	/* 256 / (256 - 224) = 8x */
#define IMX241_ANA_GAIN_STEP		1
#define IMX241_ANA_GAIN_DEFAULT		0

#define IMX241_REG_DGAIN_GR		CCI_REG16(0x020e)
#define IMX241_REG_DGAIN_R		CCI_REG16(0x0210)
#define IMX241_REG_DGAIN_B		CCI_REG16(0x0212)
#define IMX241_REG_DGAIN_GB		CCI_REG16(0x0214)
#define IMX241_DGTL_GAIN_MIN		0x0100
#define IMX241_DGTL_GAIN_MAX		0x0fff
#define IMX241_DGTL_GAIN_DEFAULT	0x0100
#define IMX241_DGTL_GAIN_STEP		1

#define IMX241_REG_FRAME_LENGTH		CCI_REG16(0x0340)
#define IMX241_FLL_MAX			0xffff
#define IMX241_VBLANK_MIN		32

#define IMX241_REG_TEST_PATTERN		CCI_REG16(0x0600)

#define IMX241_LINK_FREQ		498333333ULL
#define IMX241_DATA_LANES		2
#define IMX241_PIXEL_RATE		(IMX241_LINK_FREQ * 2 * IMX241_DATA_LANES / 10)
#define IMX241_XCLK_FREQ		(26 * HZ_PER_MHZ)

#define IMX241_NATIVE_WIDTH		2592U
#define IMX241_NATIVE_HEIGHT		1944U

/* 2592x1944, 30 fps, 26 MHz clock (Windows driver table 5 of 6) */
static const struct cci_reg_sequence imx241_2592x1944_regs[] = {
	{ CCI_REG8(0x0101), 0x00 },
	{ CCI_REG8(0x303c), 0x3b },
	{ CCI_REG8(0x303d), 0x00 },
	{ CCI_REG8(0x3041), 0xd7 },
	{ CCI_REG8(0x30e0), 0x00 },
	{ CCI_REG8(0x30e1), 0x00 },
	{ CCI_REG8(0x30f6), 0x00 },
	{ CCI_REG8(0x34ce), 0xff },
	{ CCI_REG8(0x0340), 0x08 },
	{ CCI_REG8(0x0341), 0xe9 },
	{ CCI_REG8(0x0342), 0x05 },
	{ CCI_REG8(0x0343), 0xb0 },
	{ CCI_REG8(0x0344), 0x00 },
	{ CCI_REG8(0x0345), 0x00 },
	{ CCI_REG8(0x0346), 0x00 },
	{ CCI_REG8(0x0347), 0x00 },
	{ CCI_REG8(0x0348), 0x0a },
	{ CCI_REG8(0x0349), 0x1f },
	{ CCI_REG8(0x034a), 0x07 },
	{ CCI_REG8(0x034b), 0x97 },
	{ CCI_REG8(0x0381), 0x01 },
	{ CCI_REG8(0x0383), 0x01 },
	{ CCI_REG8(0x0385), 0x01 },
	{ CCI_REG8(0x0387), 0x01 },
	{ CCI_REG8(0x3048), 0x20 },
	{ CCI_REG8(0x30d5), 0x00 },
	{ CCI_REG8(0x3165), 0x20 },
	{ CCI_REG8(0x30d1), 0x00 },
	{ CCI_REG8(0x30d0), 0x2a },
	{ CCI_REG8(0x3102), 0x13 },
	{ CCI_REG8(0x3103), 0x47 },
	{ CCI_REG8(0x3049), 0x01 },
	{ CCI_REG8(0x304d), 0x02 },
	{ CCI_REG8(0x304c), 0xd7 },
	{ CCI_REG8(0x0112), 0x0a },
	{ CCI_REG8(0x0113), 0x0a },
	{ CCI_REG8(0x034c), 0x0a },
	{ CCI_REG8(0x034d), 0x20 },
	{ CCI_REG8(0x034e), 0x07 },
	{ CCI_REG8(0x034f), 0x98 },
	{ CCI_REG8(0x0305), 0x03 },
	{ CCI_REG8(0x0307), 0x73 },
	{ CCI_REG8(0x3037), 0x0a },
	{ CCI_REG8(0x3038), 0x01 },
	{ CCI_REG8(0x303e), 0x01 },
	{ CCI_REG8(0x30a2), 0x0e },
	{ CCI_REG8(0x30a5), 0x60 },
	{ CCI_REG8(0x30a7), 0x40 },
	{ CCI_REG8(0x31aa), 0x02 },
	{ CCI_REG8(0x0306), 0x00 },
	{ CCI_REG8(0x0309), 0x0a },
	{ CCI_REG8(0x030d), 0x0f },
	{ CCI_REG8(0x030e), 0x03 },
	{ CCI_REG8(0x030f), 0x41 },
	{ CCI_REG8(0x0310), 0x00 },
	{ CCI_REG8(0x3301), 0x00 },
	{ CCI_REG8(0x3318), 0x60 },
	{ CCI_REG8(0x0202), 0x08 },
	{ CCI_REG8(0x0203), 0xe4 },
	{ CCI_REG8(0x0204), 0x00 },
	{ CCI_REG8(0x0205), 0x00 },
	{ CCI_REG8(0x020e), 0x01 },
	{ CCI_REG8(0x020f), 0x00 },
	{ CCI_REG8(0x0210), 0x01 },
	{ CCI_REG8(0x0211), 0x00 },
	{ CCI_REG8(0x0212), 0x01 },
	{ CCI_REG8(0x0213), 0x00 },
	{ CCI_REG8(0x0214), 0x01 },
	{ CCI_REG8(0x0215), 0x00 },
};

/* 1296x972 (H binning, V subsampling), 30 fps, 26 MHz clock (table 6 of 6) */
static const struct cci_reg_sequence imx241_1296x972_regs[] = {
	{ CCI_REG8(0x0101), 0x00 },
	{ CCI_REG8(0x303c), 0x3b },
	{ CCI_REG8(0x303d), 0x00 },
	{ CCI_REG8(0x3041), 0xd7 },
	{ CCI_REG8(0x30e0), 0x00 },
	{ CCI_REG8(0x30e1), 0x00 },
	{ CCI_REG8(0x30f6), 0x00 },
	{ CCI_REG8(0x34ce), 0xff },
	{ CCI_REG8(0x0340), 0x08 },
	{ CCI_REG8(0x0341), 0x1c },
	{ CCI_REG8(0x0342), 0x06 },
	{ CCI_REG8(0x0343), 0x40 },
	{ CCI_REG8(0x0344), 0x00 },
	{ CCI_REG8(0x0345), 0x00 },
	{ CCI_REG8(0x0346), 0x00 },
	{ CCI_REG8(0x0347), 0x00 },
	{ CCI_REG8(0x0348), 0x0a },
	{ CCI_REG8(0x0349), 0x1f },
	{ CCI_REG8(0x034a), 0x07 },
	{ CCI_REG8(0x034b), 0x97 },
	{ CCI_REG8(0x0381), 0x01 },
	{ CCI_REG8(0x0383), 0x01 },
	{ CCI_REG8(0x0385), 0x01 },
	{ CCI_REG8(0x0387), 0x03 },
	{ CCI_REG8(0x3048), 0x25 },
	{ CCI_REG8(0x30d5), 0x00 },
	{ CCI_REG8(0x3165), 0x28 },
	{ CCI_REG8(0x30d1), 0x00 },
	{ CCI_REG8(0x30d0), 0x2a },
	{ CCI_REG8(0x3102), 0x13 },
	{ CCI_REG8(0x3103), 0x47 },
	{ CCI_REG8(0x3049), 0x01 },
	{ CCI_REG8(0x304d), 0x02 },
	{ CCI_REG8(0x304c), 0xd7 },
	{ CCI_REG8(0x0112), 0x0a },
	{ CCI_REG8(0x0113), 0x0a },
	{ CCI_REG8(0x034c), 0x05 },
	{ CCI_REG8(0x034d), 0x10 },
	{ CCI_REG8(0x034e), 0x03 },
	{ CCI_REG8(0x034f), 0xcc },
	{ CCI_REG8(0x0305), 0x03 },
	{ CCI_REG8(0x0307), 0x73 },
	{ CCI_REG8(0x3037), 0x0a },
	{ CCI_REG8(0x3038), 0x01 },
	{ CCI_REG8(0x303e), 0x01 },
	{ CCI_REG8(0x30a2), 0x0e },
	{ CCI_REG8(0x30a5), 0x60 },
	{ CCI_REG8(0x30a7), 0x40 },
	{ CCI_REG8(0x31aa), 0x02 },
	{ CCI_REG8(0x0306), 0x00 },
	{ CCI_REG8(0x0309), 0x0a },
	{ CCI_REG8(0x030d), 0x0f },
	{ CCI_REG8(0x030e), 0x03 },
	{ CCI_REG8(0x030f), 0x41 },
	{ CCI_REG8(0x0310), 0x00 },
	{ CCI_REG8(0x3301), 0x00 },
	{ CCI_REG8(0x3318), 0x60 },
	{ CCI_REG8(0x0202), 0x08 },
	{ CCI_REG8(0x0203), 0x17 },
	{ CCI_REG8(0x0204), 0x00 },
	{ CCI_REG8(0x0205), 0x00 },
	{ CCI_REG8(0x020e), 0x01 },
	{ CCI_REG8(0x020f), 0x00 },
	{ CCI_REG8(0x0210), 0x01 },
	{ CCI_REG8(0x0211), 0x00 },
	{ CCI_REG8(0x0212), 0x01 },
	{ CCI_REG8(0x0213), 0x00 },
	{ CCI_REG8(0x0214), 0x01 },
	{ CCI_REG8(0x0215), 0x00 },
};


struct imx241_mode {
	u32 width;
	u32 height;
	u32 line_length;	/* LINE_LENGTH_PCK register value (2 pixels each) */
	u32 fll_def;		/* default frame length (30 fps) */
	struct v4l2_rect crop;
	const struct cci_reg_sequence *regs;
	unsigned int num_regs;
};

static const struct imx241_mode supported_modes[] = {
	{
		.width = 2592,
		.height = 1944,
		.line_length = 1456,
		.fll_def = 2281,
		.crop = { .left = 0, .top = 0, .width = 2592, .height = 1944 },
		.regs = imx241_2592x1944_regs,
		.num_regs = ARRAY_SIZE(imx241_2592x1944_regs),
	},
	{
		.width = 1296,
		.height = 972,
		.line_length = 1600,
		.fll_def = 2076,
		.crop = { .left = 0, .top = 0, .width = 2592, .height = 1944 },
		.regs = imx241_1296x972_regs,
		.num_regs = ARRAY_SIZE(imx241_1296x972_regs),
	},
};

static const s64 imx241_link_freq_menu[] = {
	IMX241_LINK_FREQ,
};

static const char * const imx241_test_pattern_menu[] = {
	"Disabled",
	"Solid Colour",
	"Colour Bars",
	"Fade to Grey Colour Bars",
	"PN9",
};

static const char * const imx241_supply_names[] = {
	"dovdd",	/* digital I/O */
	"avdd",		/* analogue */
	"dvdd",		/* digital core */
};

/*
 * The front camera of the Galaxy Book 10.6 shows a mirror image by default
 * (user request): the sensor's horizontal mirror is on while the HFLIP
 * control is 0, and HFLIP = 1 gives the unmirrored image. libcamera resets
 * the flip controls to 0 whenever it configures the camera, so this cannot
 * be done with the control's default value. mirror=0 restores the plain
 * behaviour.
 */
static bool mirror = true;
module_param(mirror, bool, 0444);
MODULE_PARM_DESC(mirror, "mirror the image while HFLIP is 0 (default: on)");

/* Bayer order for [vflip][effective mirror] (sensor order without flips: RGGB) */
static const u32 imx241_mbus_codes[2][2] = {
	{ MEDIA_BUS_FMT_SRGGB10_1X10, MEDIA_BUS_FMT_SGRBG10_1X10 },
	{ MEDIA_BUS_FMT_SGBRG10_1X10, MEDIA_BUS_FMT_SBGGR10_1X10 },
};

struct imx241 {
	struct device *dev;
	struct v4l2_subdev sd;
	struct media_pad pad;
	struct regmap *regmap;

	struct clk *xclk;
	struct gpio_desc *reset;
	struct regulator_bulk_data supplies[ARRAY_SIZE(imx241_supply_names)];

	struct v4l2_ctrl_handler ctrl_handler;
	struct v4l2_ctrl *link_freq;
	struct v4l2_ctrl *pixel_rate;
	struct v4l2_ctrl *vblank;
	struct v4l2_ctrl *hblank;
	struct v4l2_ctrl *exposure;
	struct v4l2_ctrl *hflip;
	struct v4l2_ctrl *vflip;

	const struct imx241_mode *mode;
};

static inline struct imx241 *to_imx241(struct v4l2_subdev *sd)
{
	return container_of(sd, struct imx241, sd);
}

static bool imx241_h_mirrored(struct imx241 *imx241)
{
	return (imx241->hflip && imx241->hflip->val) ^ mirror;
}

static u32 imx241_get_format_code(struct imx241 *imx241)
{
	return imx241_mbus_codes[imx241->vflip && imx241->vflip->val]
				[imx241_h_mirrored(imx241)];
}

static int imx241_set_ctrl(struct v4l2_ctrl *ctrl)
{
	struct imx241 *imx241 = container_of(ctrl->handler, struct imx241,
					     ctrl_handler);
	const struct imx241_mode *mode = imx241->mode;
	int ret = 0;

	if (ctrl->id == V4L2_CID_VBLANK) {
		/* the exposure must fit into the new frame length */
		int exposure_max = mode->height + ctrl->val - IMX241_EXPOSURE_OFFSET;

		ret = __v4l2_ctrl_modify_range(imx241->exposure,
					       imx241->exposure->minimum,
					       exposure_max,
					       imx241->exposure->step,
					       min(imx241->exposure->default_value,
						   (s64)exposure_max));
		if (ret)
			return ret;
	}

	if (pm_runtime_get_if_in_use(imx241->dev) == 0)
		return 0;

	switch (ctrl->id) {
	case V4L2_CID_EXPOSURE:
		cci_write(imx241->regmap, IMX241_REG_EXPOSURE, ctrl->val, &ret);
		break;
	case V4L2_CID_ANALOGUE_GAIN:
		cci_write(imx241->regmap, IMX241_REG_ANALOG_GAIN, ctrl->val, &ret);
		break;
	case V4L2_CID_DIGITAL_GAIN:
		cci_write(imx241->regmap, IMX241_REG_DGAIN_GR, ctrl->val, &ret);
		cci_write(imx241->regmap, IMX241_REG_DGAIN_R, ctrl->val, &ret);
		cci_write(imx241->regmap, IMX241_REG_DGAIN_B, ctrl->val, &ret);
		cci_write(imx241->regmap, IMX241_REG_DGAIN_GB, ctrl->val, &ret);
		break;
	case V4L2_CID_VBLANK:
		cci_write(imx241->regmap, IMX241_REG_FRAME_LENGTH,
			  mode->height + ctrl->val, &ret);
		break;
	case V4L2_CID_HFLIP:
	case V4L2_CID_VFLIP:
		cci_write(imx241->regmap, IMX241_REG_ORIENTATION,
			  imx241_h_mirrored(imx241) | imx241->vflip->val << 1, &ret);
		break;
	case V4L2_CID_TEST_PATTERN:
		cci_write(imx241->regmap, IMX241_REG_TEST_PATTERN, ctrl->val, &ret);
		break;
	default:
		dev_info(imx241->dev, "unhandled control 0x%x\n", ctrl->id);
		ret = -EINVAL;
		break;
	}

	pm_runtime_put(imx241->dev);

	return ret;
}

static const struct v4l2_ctrl_ops imx241_ctrl_ops = {
	.s_ctrl = imx241_set_ctrl,
};

static void imx241_update_mode_controls(struct imx241 *imx241)
{
	const struct imx241_mode *mode = imx241->mode;
	s64 hblank = mode->line_length * 2 - mode->width;
	int exposure_max = mode->fll_def - IMX241_EXPOSURE_OFFSET;

	__v4l2_ctrl_modify_range(imx241->hblank, hblank, hblank, 1, hblank);
	__v4l2_ctrl_modify_range(imx241->vblank, IMX241_VBLANK_MIN,
				 IMX241_FLL_MAX - mode->height, 1,
				 mode->fll_def - mode->height);
	__v4l2_ctrl_s_ctrl(imx241->vblank, mode->fll_def - mode->height);
	__v4l2_ctrl_modify_range(imx241->exposure, IMX241_EXPOSURE_MIN,
				 exposure_max, IMX241_EXPOSURE_STEP,
				 exposure_max);
}

static int imx241_init_controls(struct imx241 *imx241)
{
	struct v4l2_ctrl_handler *hdl = &imx241->ctrl_handler;
	const struct imx241_mode *mode = &supported_modes[0];
	struct v4l2_fwnode_device_properties props;
	s64 hblank = mode->line_length * 2 - mode->width;
	int exposure_max = mode->fll_def - IMX241_EXPOSURE_OFFSET;
	int ret;

	ret = v4l2_ctrl_handler_init(hdl, 12);
	if (ret)
		return ret;

	imx241->link_freq = v4l2_ctrl_new_int_menu(hdl, &imx241_ctrl_ops,
						   V4L2_CID_LINK_FREQ,
						   ARRAY_SIZE(imx241_link_freq_menu) - 1,
						   0, imx241_link_freq_menu);
	if (imx241->link_freq)
		imx241->link_freq->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	imx241->pixel_rate = v4l2_ctrl_new_std(hdl, &imx241_ctrl_ops,
					       V4L2_CID_PIXEL_RATE,
					       IMX241_PIXEL_RATE, IMX241_PIXEL_RATE,
					       1, IMX241_PIXEL_RATE);

	imx241->vblank = v4l2_ctrl_new_std(hdl, &imx241_ctrl_ops, V4L2_CID_VBLANK,
					   IMX241_VBLANK_MIN,
					   IMX241_FLL_MAX - mode->height, 1,
					   mode->fll_def - mode->height);

	imx241->hblank = v4l2_ctrl_new_std(hdl, &imx241_ctrl_ops, V4L2_CID_HBLANK,
					   hblank, hblank, 1, hblank);
	if (imx241->hblank)
		imx241->hblank->flags |= V4L2_CTRL_FLAG_READ_ONLY;

	imx241->exposure = v4l2_ctrl_new_std(hdl, &imx241_ctrl_ops,
					     V4L2_CID_EXPOSURE,
					     IMX241_EXPOSURE_MIN, exposure_max,
					     IMX241_EXPOSURE_STEP, exposure_max);

	v4l2_ctrl_new_std(hdl, &imx241_ctrl_ops, V4L2_CID_ANALOGUE_GAIN,
			  IMX241_ANA_GAIN_MIN, IMX241_ANA_GAIN_MAX,
			  IMX241_ANA_GAIN_STEP, IMX241_ANA_GAIN_DEFAULT);

	v4l2_ctrl_new_std(hdl, &imx241_ctrl_ops, V4L2_CID_DIGITAL_GAIN,
			  IMX241_DGTL_GAIN_MIN, IMX241_DGTL_GAIN_MAX,
			  IMX241_DGTL_GAIN_STEP, IMX241_DGTL_GAIN_DEFAULT);

	imx241->hflip = v4l2_ctrl_new_std(hdl, &imx241_ctrl_ops, V4L2_CID_HFLIP,
					  0, 1, 1, 0);
	if (imx241->hflip)
		imx241->hflip->flags |= V4L2_CTRL_FLAG_MODIFY_LAYOUT;

	imx241->vflip = v4l2_ctrl_new_std(hdl, &imx241_ctrl_ops, V4L2_CID_VFLIP,
					  0, 1, 1, 0);
	if (imx241->vflip)
		imx241->vflip->flags |= V4L2_CTRL_FLAG_MODIFY_LAYOUT;

	v4l2_ctrl_new_std_menu_items(hdl, &imx241_ctrl_ops, V4L2_CID_TEST_PATTERN,
				     ARRAY_SIZE(imx241_test_pattern_menu) - 1,
				     0, 0, imx241_test_pattern_menu);

	if (hdl->error) {
		ret = hdl->error;
		goto err_free;
	}

	ret = v4l2_fwnode_device_parse(imx241->dev, &props);
	if (ret)
		goto err_free;

	ret = v4l2_ctrl_new_fwnode_properties(hdl, &imx241_ctrl_ops, &props);
	if (ret)
		goto err_free;

	imx241->sd.ctrl_handler = hdl;

	return 0;

err_free:
	v4l2_ctrl_handler_free(hdl);
	return ret;
}

static int imx241_enable_streams(struct v4l2_subdev *sd,
				 struct v4l2_subdev_state *state, u32 pad,
				 u64 streams_mask)
{
	struct imx241 *imx241 = to_imx241(sd);
	const struct imx241_mode *mode = imx241->mode;
	int ret;

	ret = pm_runtime_resume_and_get(imx241->dev);
	if (ret < 0)
		return ret;

	ret = cci_multi_reg_write(imx241->regmap, mode->regs, mode->num_regs, NULL);
	if (ret) {
		dev_err(imx241->dev, "failed to write mode registers: %d\n", ret);
		goto err_rpm_put;
	}

	/* exposure, gains, frame length and flips as set by the user */
	ret = __v4l2_ctrl_handler_setup(imx241->sd.ctrl_handler);
	if (ret)
		goto err_rpm_put;

	ret = cci_write(imx241->regmap, IMX241_REG_MODE_SELECT,
			IMX241_MODE_STREAMING, NULL);
	if (ret)
		goto err_rpm_put;

	/* the Bayer order follows the flips: no changes while streaming */
	__v4l2_ctrl_grab(imx241->vflip, true);
	__v4l2_ctrl_grab(imx241->hflip, true);

	return 0;

err_rpm_put:
	pm_runtime_put_autosuspend(imx241->dev);
	return ret;
}

static int imx241_disable_streams(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *state, u32 pad,
				  u64 streams_mask)
{
	struct imx241 *imx241 = to_imx241(sd);
	int ret;

	ret = cci_write(imx241->regmap, IMX241_REG_MODE_SELECT,
			IMX241_MODE_STANDBY, NULL);
	if (ret)
		dev_err(imx241->dev, "failed to stop streaming: %d\n", ret);

	__v4l2_ctrl_grab(imx241->vflip, false);
	__v4l2_ctrl_grab(imx241->hflip, false);

	pm_runtime_put_autosuspend(imx241->dev);

	return ret;
}

static int imx241_enum_mbus_code(struct v4l2_subdev *sd,
				 struct v4l2_subdev_state *state,
				 struct v4l2_subdev_mbus_code_enum *code)
{
	if (code->index > 0)
		return -EINVAL;

	code->code = imx241_get_format_code(to_imx241(sd));

	return 0;
}

static int imx241_enum_frame_size(struct v4l2_subdev *sd,
				  struct v4l2_subdev_state *state,
				  struct v4l2_subdev_frame_size_enum *fse)
{
	if (fse->index >= ARRAY_SIZE(supported_modes))
		return -EINVAL;

	if (fse->code != imx241_get_format_code(to_imx241(sd)))
		return -EINVAL;

	fse->min_width = supported_modes[fse->index].width;
	fse->max_width = fse->min_width;
	fse->min_height = supported_modes[fse->index].height;
	fse->max_height = fse->min_height;

	return 0;
}

static void imx241_fill_format(struct imx241 *imx241,
			       const struct imx241_mode *mode,
			       struct v4l2_mbus_framefmt *fmt)
{
	fmt->code = imx241_get_format_code(imx241);
	fmt->width = mode->width;
	fmt->height = mode->height;
	fmt->field = V4L2_FIELD_NONE;
	fmt->colorspace = V4L2_COLORSPACE_RAW;
	fmt->ycbcr_enc = V4L2_YCBCR_ENC_601;
	fmt->quantization = V4L2_QUANTIZATION_FULL_RANGE;
	fmt->xfer_func = V4L2_XFER_FUNC_NONE;
}

static int imx241_set_pad_format(struct v4l2_subdev *sd,
				 struct v4l2_subdev_state *state,
				 struct v4l2_subdev_format *fmt)
{
	struct imx241 *imx241 = to_imx241(sd);
	const struct imx241_mode *mode;

	mode = v4l2_find_nearest_size(supported_modes,
				      ARRAY_SIZE(supported_modes),
				      width, height,
				      fmt->format.width, fmt->format.height);

	imx241_fill_format(imx241, mode, &fmt->format);
	*v4l2_subdev_state_get_format(state, 0) = fmt->format;
	*v4l2_subdev_state_get_crop(state, 0) = mode->crop;

	if (fmt->which == V4L2_SUBDEV_FORMAT_ACTIVE) {
		imx241->mode = mode;
		imx241_update_mode_controls(imx241);
	}

	return 0;
}

static int imx241_get_selection(struct v4l2_subdev *sd,
				struct v4l2_subdev_state *state,
				struct v4l2_subdev_selection *sel)
{
	switch (sel->target) {
	case V4L2_SEL_TGT_CROP:
		sel->r = *v4l2_subdev_state_get_crop(state, 0);
		return 0;
	case V4L2_SEL_TGT_NATIVE_SIZE:
	case V4L2_SEL_TGT_CROP_DEFAULT:
	case V4L2_SEL_TGT_CROP_BOUNDS:
		sel->r.top = 0;
		sel->r.left = 0;
		sel->r.width = IMX241_NATIVE_WIDTH;
		sel->r.height = IMX241_NATIVE_HEIGHT;
		return 0;
	}

	return -EINVAL;
}

static int imx241_init_state(struct v4l2_subdev *sd,
			     struct v4l2_subdev_state *state)
{
	struct v4l2_subdev_format fmt = {
		.which = V4L2_SUBDEV_FORMAT_TRY,
		.pad = 0,
		.format = {
			.width = supported_modes[0].width,
			.height = supported_modes[0].height,
		},
	};

	return imx241_set_pad_format(sd, state, &fmt);
}

static const struct v4l2_subdev_video_ops imx241_video_ops = {
	.s_stream = v4l2_subdev_s_stream_helper,
};

static const struct v4l2_subdev_pad_ops imx241_pad_ops = {
	.enum_mbus_code = imx241_enum_mbus_code,
	.get_fmt = v4l2_subdev_get_fmt,
	.set_fmt = imx241_set_pad_format,
	.get_selection = imx241_get_selection,
	.enum_frame_size = imx241_enum_frame_size,
	.enable_streams = imx241_enable_streams,
	.disable_streams = imx241_disable_streams,
};

static const struct v4l2_subdev_ops imx241_subdev_ops = {
	.video = &imx241_video_ops,
	.pad = &imx241_pad_ops,
};

static const struct v4l2_subdev_internal_ops imx241_internal_ops = {
	.init_state = imx241_init_state,
};

static int imx241_power_on(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct imx241 *imx241 = to_imx241(sd);
	int ret;

	ret = regulator_bulk_enable(ARRAY_SIZE(imx241->supplies), imx241->supplies);
	if (ret) {
		dev_err(dev, "failed to enable supplies: %d\n", ret);
		return ret;
	}

	ret = clk_prepare_enable(imx241->xclk);
	if (ret) {
		dev_err(dev, "failed to enable clock: %d\n", ret);
		goto err_supplies;
	}

	usleep_range(1000, 2000);
	gpiod_set_value_cansleep(imx241->reset, 0);
	/* time from reset release until the sensor answers on I2C */
	usleep_range(10000, 11000);

	return 0;

err_supplies:
	regulator_bulk_disable(ARRAY_SIZE(imx241->supplies), imx241->supplies);
	return ret;
}

static int imx241_power_off(struct device *dev)
{
	struct v4l2_subdev *sd = dev_get_drvdata(dev);
	struct imx241 *imx241 = to_imx241(sd);

	gpiod_set_value_cansleep(imx241->reset, 1);
	clk_disable_unprepare(imx241->xclk);
	regulator_bulk_disable(ARRAY_SIZE(imx241->supplies), imx241->supplies);

	return 0;
}

static int imx241_identify(struct imx241 *imx241)
{
	u64 val;
	int ret;

	ret = cci_read(imx241->regmap, IMX241_REG_MODEL_ID, &val, NULL);
	if (ret)
		return dev_err_probe(imx241->dev, ret, "failed to read model id\n");

	if (val != IMX241_MODEL_ID)
		return dev_err_probe(imx241->dev, -ENODEV,
				     "model id 0x%04llx, expected 0x%04x\n",
				     val, IMX241_MODEL_ID);

	return 0;
}

static int imx241_check_hwcfg(struct imx241 *imx241)
{
	struct v4l2_fwnode_endpoint ep = { .bus_type = V4L2_MBUS_CSI2_DPHY };
	struct fwnode_handle *endpoint;
	unsigned long link_freq_bitmap;
	int ret;

	/* the endpoint is created by ipu-bridge once the CIO2 is up */
	endpoint = fwnode_graph_get_next_endpoint(dev_fwnode(imx241->dev), NULL);
	if (!endpoint)
		return dev_err_probe(imx241->dev, -EPROBE_DEFER,
				     "waiting for the fwnode graph endpoint\n");

	ret = v4l2_fwnode_endpoint_alloc_parse(endpoint, &ep);
	fwnode_handle_put(endpoint);
	if (ret)
		return dev_err_probe(imx241->dev, ret, "failed to parse endpoint\n");

	if (ep.bus.mipi_csi2.num_data_lanes != IMX241_DATA_LANES) {
		ret = dev_err_probe(imx241->dev, -EINVAL,
				    "%u data lanes, only %u supported\n",
				    ep.bus.mipi_csi2.num_data_lanes,
				    IMX241_DATA_LANES);
		goto out;
	}

	ret = v4l2_link_freq_to_bitmap(imx241->dev, ep.link_frequencies,
				       ep.nr_of_link_frequencies,
				       imx241_link_freq_menu,
				       ARRAY_SIZE(imx241_link_freq_menu),
				       &link_freq_bitmap);
out:
	v4l2_fwnode_endpoint_free(&ep);
	return ret;
}

static int imx241_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct imx241 *imx241;
	unsigned long rate;
	unsigned int i;
	int ret;

	imx241 = devm_kzalloc(dev, sizeof(*imx241), GFP_KERNEL);
	if (!imx241)
		return -ENOMEM;

	imx241->dev = dev;
	v4l2_i2c_subdev_init(&imx241->sd, client, &imx241_subdev_ops);
	imx241->sd.internal_ops = &imx241_internal_ops;

	ret = imx241_check_hwcfg(imx241);
	if (ret)
		return ret;

	imx241->regmap = devm_cci_regmap_init_i2c(client, 16);
	if (IS_ERR(imx241->regmap))
		return dev_err_probe(dev, PTR_ERR(imx241->regmap),
				     "failed to init CCI\n");

	imx241->xclk = devm_clk_get(dev, NULL);
	if (IS_ERR(imx241->xclk))
		return dev_err_probe(dev, PTR_ERR(imx241->xclk),
				     "failed to get clock\n");

	rate = clk_get_rate(imx241->xclk);
	if (rate != IMX241_XCLK_FREQ)
		return dev_err_probe(dev, -EINVAL,
				     "clock %lu Hz, only 26 MHz is supported\n",
				     rate);

	for (i = 0; i < ARRAY_SIZE(imx241_supply_names); i++)
		imx241->supplies[i].supply = imx241_supply_names[i];
	ret = devm_regulator_bulk_get(dev, ARRAY_SIZE(imx241->supplies),
				      imx241->supplies);
	if (ret)
		return dev_err_probe(dev, ret, "failed to get supplies\n");

	imx241->reset = devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_HIGH);
	if (IS_ERR(imx241->reset))
		return dev_err_probe(dev, PTR_ERR(imx241->reset),
				     "failed to get reset GPIO\n");

	ret = imx241_power_on(dev);
	if (ret)
		return ret;

	ret = imx241_identify(imx241);
	if (ret)
		goto err_power_off;

	imx241->mode = &supported_modes[0];

	ret = imx241_init_controls(imx241);
	if (ret)
		goto err_power_off;

	imx241->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	imx241->sd.entity.function = MEDIA_ENT_F_CAM_SENSOR;
	imx241->pad.flags = MEDIA_PAD_FL_SOURCE;

	ret = media_entity_pads_init(&imx241->sd.entity, 1, &imx241->pad);
	if (ret) {
		dev_err_probe(dev, ret, "failed to init entity pads\n");
		goto err_free_controls;
	}

	imx241->sd.state_lock = imx241->ctrl_handler.lock;
	ret = v4l2_subdev_init_finalize(&imx241->sd);
	if (ret) {
		dev_err_probe(dev, ret, "subdev init failed\n");
		goto err_entity_cleanup;
	}

	pm_runtime_set_active(dev);
	pm_runtime_enable(dev);

	ret = v4l2_async_register_subdev_sensor(&imx241->sd);
	if (ret) {
		dev_err_probe(dev, ret, "failed to register sensor sub-device\n");
		goto err_subdev_cleanup;
	}

	pm_runtime_idle(dev);
	pm_runtime_set_autosuspend_delay(dev, 1000);
	pm_runtime_use_autosuspend(dev);

	dev_info(dev, "Sony IMX241 found, %u data lanes, %llu Hz link\n",
		 IMX241_DATA_LANES, IMX241_LINK_FREQ);

	return 0;

err_subdev_cleanup:
	v4l2_subdev_cleanup(&imx241->sd);
	pm_runtime_disable(dev);
	pm_runtime_set_suspended(dev);
err_entity_cleanup:
	media_entity_cleanup(&imx241->sd.entity);
err_free_controls:
	v4l2_ctrl_handler_free(&imx241->ctrl_handler);
err_power_off:
	imx241_power_off(dev);

	return ret;
}

static void imx241_remove(struct i2c_client *client)
{
	struct v4l2_subdev *sd = i2c_get_clientdata(client);
	struct imx241 *imx241 = to_imx241(sd);

	v4l2_async_unregister_subdev(sd);
	v4l2_subdev_cleanup(sd);
	media_entity_cleanup(&sd->entity);
	v4l2_ctrl_handler_free(&imx241->ctrl_handler);

	pm_runtime_disable(&client->dev);
	if (!pm_runtime_status_suspended(&client->dev)) {
		imx241_power_off(&client->dev);
		pm_runtime_set_suspended(&client->dev);
	}
}

static DEFINE_RUNTIME_DEV_PM_OPS(imx241_pm_ops, imx241_power_off,
				 imx241_power_on, NULL);

static const struct acpi_device_id imx241_acpi_ids[] = {
	{ "INT347F" },
	{ }
};
MODULE_DEVICE_TABLE(acpi, imx241_acpi_ids);

static struct i2c_driver imx241_i2c_driver = {
	.driver = {
		.name = "imx241",
		.acpi_match_table = imx241_acpi_ids,
		.pm = pm_ptr(&imx241_pm_ops),
	},
	.probe = imx241_probe,
	.remove = imx241_remove,
};
module_i2c_driver(imx241_i2c_driver);

MODULE_DESCRIPTION("Sony IMX241 camera sensor driver");
MODULE_LICENSE("GPL");
