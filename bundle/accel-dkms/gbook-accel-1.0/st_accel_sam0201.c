// SPDX-License-Identifier: GPL-2.0-only
/*
 * ACPI glue for the Samsung/Kionix K2HH accelerometer exposed as ACPI device
 * SAM0201 in the 2017 Samsung Galaxy Book 10.6 and Galaxy Book 12 tablets.
 *
 * The part is register compatible with the ST LIS2HH12, which the in-tree
 * st_accel driver supports, but the in-tree I2C glue does not list the
 * SAM0201 ACPI ID.  This module repeats the probe path of
 * drivers/iio/accel/st_accel_i2c.c for that single ID, so no in-tree module
 * has to be patched or replaced.
 *
 * Based on st_accel_i2c.c, Copyright (C) 2012-2013 STMicroelectronics Inc.
 */

#include <linux/acpi.h>
#include <linux/i2c.h>
#include <linux/kernel.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/version.h>

#include <linux/iio/iio.h>
#include <linux/iio/common/st_sensors.h>
#include <linux/iio/common/st_sensors_i2c.h>

#define LIS2HH12_ACCEL_DEV_NAME		"lis2hh12"

/*
 * Exported by the in-tree st_accel core module (symbol namespace
 * IIO_ST_SENSORS); declared in the private header drivers/iio/accel/st_accel.h.
 */
const struct st_sensor_settings *st_accel_get_settings(const char *name);
int st_accel_common_probe(struct iio_dev *indio_dev);

static const struct acpi_device_id st_accel_sam0201_acpi_match[] = {
	{ "SAM0201", (kernel_ulong_t)LIS2HH12_ACCEL_DEV_NAME },
	{ }
};
MODULE_DEVICE_TABLE(acpi, st_accel_sam0201_acpi_match);

static int st_accel_sam0201_probe(struct i2c_client *client)
{
	const struct st_sensor_settings *settings;
	struct st_sensor_data *adata;
	struct iio_dev *indio_dev;
	int ret;

	st_sensors_dev_name_probe(&client->dev, client->name, sizeof(client->name));

	settings = st_accel_get_settings(client->name);
	if (!settings) {
		dev_err(&client->dev, "device name %s not recognized.\n",
			client->name);
		return -ENODEV;
	}

	indio_dev = devm_iio_device_alloc(&client->dev, sizeof(*adata));
	if (!indio_dev)
		return -ENOMEM;

	adata = iio_priv(indio_dev);
	adata->sensor_settings = (struct st_sensor_settings *)settings;

	ret = st_sensors_i2c_configure(indio_dev, client);
	if (ret < 0)
		return ret;

	ret = st_sensors_power_enable(indio_dev);
	if (ret)
		return ret;

	return st_accel_common_probe(indio_dev);
}

static struct i2c_driver st_accel_sam0201_driver = {
	.driver = {
		.name = "st-accel-sam0201",
		.acpi_match_table = st_accel_sam0201_acpi_match,
	},
	.probe = st_accel_sam0201_probe,
};
module_i2c_driver(st_accel_sam0201_driver);

MODULE_DESCRIPTION("Samsung SAM0201 (K2HH / LIS2HH12 compatible) accelerometer ACPI glue");
MODULE_LICENSE("GPL v2");
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
MODULE_IMPORT_NS("IIO_ST_SENSORS");
#else
MODULE_IMPORT_NS(IIO_ST_SENSORS);
#endif
