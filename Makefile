ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTLiquidGlass

YTLiquidGlass_FILES = Tweak.xm
YTLiquidGlass_CFLAGS = -fobjc-arc
YTLiquidGlass_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
