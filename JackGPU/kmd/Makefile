# JackGPU KMD — WDK Build Makefile
#
# Build from a WDK/VS Developer Command Prompt:
#   nmake /f Makefile
#
# Or use the Visual Studio project:
#   msbuild jackgpu_kmd.vcxproj /p:Configuration=Release /p:Platform=ARM64

# WDK paths (adjust for your installation)
WDK_ROOT = C:\Program Files (x86)\Windows Kits\10
WDK_VER  = 10.0.22621.0
WDK_INC  = $(WDK_ROOT)\Include\$(WDK_VER)
WDK_LIB  = $(WDK_ROOT)\Lib\$(WDK_VER)

# Target architecture: ARM64 or x64
!IF "$(PLATFORM)" == ""
PLATFORM = ARM64
!ENDIF

!IF "$(PLATFORM)" == "ARM64"
ARCH = arm64
CL_ARCH = /D_ARM64_ /D_WIN64
!ELSE
ARCH = x64
CL_ARCH = /D_AMD64_ /D_WIN64
!ENDIF

CC = cl.exe
LINK = link.exe

INCLUDES = \
    /I"$(WDK_INC)\km" \
    /I"$(WDK_INC)\km\crt" \
    /I"$(WDK_INC)\shared" \
    /I"."

CFLAGS = /nologo /W4 /WX /Zi /Oi /Gz \
    /D_KERNEL_MODE /DNTDDI_VERSION=0x0A00000C \
    /DWINVER=0x0A00 /D_WIN32_WINNT=0x0A00 \
    /DPOOL_NX_OPTIN=1 \
    $(CL_ARCH) \
    $(INCLUDES) \
    /kernel

LIBS = \
    "$(WDK_LIB)\km\$(ARCH)\ntoskrnl.lib" \
    "$(WDK_LIB)\km\$(ARCH)\hal.lib" \
    "$(WDK_LIB)\km\$(ARCH)\displib.lib" \
    "$(WDK_LIB)\km\$(ARCH)\dxgkrnl.lib"

LDFLAGS = /nologo /DEBUG /DRIVER /KERNEL \
    /SUBSYSTEM:NATIVE /ENTRY:DriverEntry \
    /OUT:jackgpu_kmd.sys

OBJS = jackgpu_kmd.obj virtqueue.obj escape.obj

all: jackgpu_kmd.sys

jackgpu_kmd.sys: $(OBJS)
	$(LINK) $(LDFLAGS) $(OBJS) $(LIBS)

.c.obj:
	$(CC) $(CFLAGS) /c $<

clean:
	-del *.obj *.sys *.pdb *.exp *.lib 2>nul

# Package driver for installation
package: jackgpu_kmd.sys
	@echo Creating driver package...
	@if not exist package mkdir package
	@copy jackgpu_kmd.sys package\
	@copy jackgpu_kmd.inf package\
	@echo.
	@echo To sign and install:
	@echo   1. makecert -r -pe -ss PrivateCertStore -n "CN=JackGPU Test" jackgpu_test.cer
	@echo   2. signtool sign /s PrivateCertStore /n "JackGPU Test" package\jackgpu_kmd.sys
	@echo   3. inf2cat /driver:package /os:10_ARM64
	@echo   4. signtool sign /s PrivateCertStore /n "JackGPU Test" package\jackgpu_kmd.cat
	@echo   5. pnputil /add-driver package\jackgpu_kmd.inf /install
