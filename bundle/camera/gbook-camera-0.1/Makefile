# gbook-camera: Galaxy Book 10.6 front camera (Sony IMX241 on Intel IPU3 CIO2)
#   int3472/     intel_skl_int3472_discrete with two more supply GPIO types
#   ipu-bridge/  ipu-bridge with the INT347F sensor entry
#   imx241/      sensor driver
obj-m += intel_skl_int3472_discrete.o ipu-bridge.o imx241.o
intel_skl_int3472_discrete-y := int3472/discrete.o int3472/discrete_quirks.o \
				int3472/clk_and_regulator.o int3472/led.o
ipu-bridge-y := ipu-bridge/ipu-bridge.o
imx241-y := imx241/imx241.o

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
