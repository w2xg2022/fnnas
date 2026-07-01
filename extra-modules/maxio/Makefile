obj-m := maxio.o

# KVER 可由外部指定（打包注入时用镜像自带的内核版本，而非构建机的 uname -r）
KVER ?= $(shell uname -r)
KDIR := /lib/modules/$(KVER)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
