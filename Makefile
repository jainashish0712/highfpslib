ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    TARGET = iphone:clang:16.5:15.0
else
    TARGET = iphone:clang:14.5:7.0
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CAHighFPS

$(TWEAK_NAME)_FILES = Tweak.x
$(TWEAK_NAME)_CFLAGS = -fobjc-arc
$(TWEAK_NAME)_FRAMEWORKS = UIKit QuartzCore Metal Foundation CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk
