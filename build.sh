#!/bin/sh
set -e # Oprește scriptul dacă vreo comandă returnează eroare

echo "-----------------------------------------------"
echo "Initializing Build Environment..."
echo "-----------------------------------------------"

export ARCH=arm64
export SUBARCH=arm64

# 1. Configurare Căi Toolchain (LLVM / Clang 21)
TOOLCHAIN_DIR="$(pwd)/llvm-21"
export PATH="${TOOLCHAIN_DIR}/bin:$PATH"

# 2. Definiții Compilatoare și Linkere
export CC="${TOOLCHAIN_DIR}/bin/clang"
export REAL_CC="${TOOLCHAIN_DIR}/bin/clang"
export CROSS_COMPILE=aarch64-linux-gnu-
export CLANG_TRIPLE=aarch64-linux-gnu-
export DTC_EXT=$(pwd)/tools/dtc
export KCFLAGS="-Wno-strict-prototypes -Wno-implicit-int -Wno-return-type -Wno-int-conversion -Wno-array-parameter"

# 3. Bypass pentru wrapper-ele Samsung/Qualcomm hardcodate
export USE_SEC_WRAPPER=0

OUT_DIR="$(pwd)/out"
DEFCONFIG_NAME="sm8150_sec_r5q_eur_open_defconfig"

# Parametrii globali de compilare
BUILD_VAR="-j$(nproc) O=${OUT_DIR} ARCH=arm64 CC=${CC} REAL_CC=${REAL_CC} CROSS_COMPILE=${CROSS_COMPILE} CLANG_TRIPLE=${CLANG_TRIPLE}  DTC=dtc LD=ld.lld HOSTLD=ld.lld LLVM=1 LLVM_IAS=1"

# Rezolvare incompatibilitate Python 2 în scripturile vechi ale kernel-ului (ex: gcc-wrapper.py)
if [ -f "scripts/gcc-wrapper.py" ]; then
    echo "Applying compatibility fix to scripts/gcc-wrapper.py..."
    sed -i 's/print >> sys.stderr, \(.*\)/import sys; print(\1, file=sys.stderr)/g' scripts/gcc-wrapper.py 2>/dev/null || true
fi

build_kernel() {
    echo "-----------------------------------------------"
    echo "Beginning kernel compilation..."
    echo "-----------------------------------------------"

    mkdir -p "${OUT_DIR}"

    # Generăm fișierul de configurare .config din defconfig-ul Samsung
    make ${BUILD_VAR} ${DEFCONFIG_NAME}

    # Injectăm setările ThinLTO direct în .config (evităm alterarea fișierelor din arch/arm64/configs)
    echo "CONFIG_THINLTO=n" >> "${OUT_DIR}/.config"
    echo "CONFIG_LTO_NONE=y" >> "${OUT_DIR}/.config"
    echo "CONFIG_LTO_CLANG=n" >> "${OUT_DIR}/.config"

    # Actualizăm .config cu noile opțiuni fără interacțiune
    make ${BUILD_VAR} olddefconfig

    # Compilăm imaginea principală (Image)
    make ${BUILD_VAR}
}

build_dtb() {
    echo "-----------------------------------------------"
    echo "Building dtb..."
    echo "-----------------------------------------------"
    
    make ${BUILD_VAR} dtbs

    DTB_DIR="${OUT_DIR}/arch/arm64/boot/dts/qcom"

    if [ -f "${DTB_DIR}/sm8150.dtb" ] && [ -f "${DTB_DIR}/sm8150-v2.dtb" ]; then
        cat "${DTB_DIR}/sm8150.dtb" "${DTB_DIR}/sm8150-v2.dtb" > "${OUT_DIR}/arch/arm64/boot/dts/dtb"
        echo "DTB concatenation successful."
    else
        echo "Error: Required DTB files missing in ${DTB_DIR}!"
        exit 1
    fi
}

build_dtbo() {
    echo "-----------------------------------------------"
    echo "Building dtbo.img..."
    echo "-----------------------------------------------"
    
    DTBO_SEARCH_DIR="${OUT_DIR}/arch/arm64/boot/dts/samsung/renovation"
    
    # Selectăm fișierele .dtbo generate pentru r5q
    DTBO_FILES=$(find "${DTBO_SEARCH_DIR}" -name "sm8150-sec-r5q-*.dtbo" 2>/dev/null | tr '\n' ' ')

    if [ -z "${DTBO_FILES}" ]; then
        echo "Error: No DTBO overlay files found in ${DTBO_SEARCH_DIR}!"
        exit 1
    fi

    "$(pwd)/tools/mkdtimg" create "${OUT_DIR}/dtbo.img" --page_size=4096 ${DTBO_FILES}
    mv "${OUT_DIR}/dtbo.img" ./dtbo.img
    echo "dtbo.img generated successfully."
}

build_boot() {
    echo "-----------------------------------------------"
    echo "Building boot.img..."
    echo "-----------------------------------------------"
    
    MKBOOTIMG="$(pwd)/tools/mkbootimg.py"
    OUT_KERNEL="${OUT_DIR}/arch/arm64/boot/Image"
    DTB_OUT="${OUT_DIR}/arch/arm64/boot/dts/dtb"
    BOOT_DIR="$(pwd)/boot"
    RAMDISK_DIR="${BOOT_DIR}/ramdisk"
    
    # Asigurăm existența directorului ramdisk pentru a preveni erorile 'find'
    mkdir -p "${RAMDISK_DIR}"
    
    # Căutăm fișierul ramdisk (.cpio, .img, .zip) atât în boot/ cât și în boot/ramdisk/
    FINAL_RAMDISK=$(find "${BOOT_DIR}" -maxdepth 2 -type f \( -name "*.cpio*" -o -name "*.img" -o -name "ramdisk*" \) | head -n 1)
    
    # Dacă este un arhivă zip, o extragem
    if [[ "${FINAL_RAMDISK}" == *.zip ]]; then
        echo "Found zipped ramdisk: ${FINAL_RAMDISK}. Extracting..."
        mkdir -p "${RAMDISK_DIR}/extracted"
        unzip -o "${FINAL_RAMDISK}" -d "${RAMDISK_DIR}/extracted/"
        FINAL_RAMDISK=$(find "${RAMDISK_DIR}/extracted" -type f \( -name "*.cpio*" -o -name "*.img" \) | head -n 1)
    fi

    if [ -z "${FINAL_RAMDISK}" ] || [ ! -f "${FINAL_RAMDISK}" ]; then
        echo "Error: No valid ramdisk file found in ${BOOT_DIR} or ${RAMDISK_DIR}!"
        exit 1
    fi

    echo "Using ramdisk file: ${FINAL_RAMDISK}"

    # Format YYYY-MM-DD valid pentru header v2 în mkbootimg
    MONTH="$(date +%Y-%m-01)"

    CMDLINE="console=null androidboot.hardware=qcom androidboot.memcg=1 lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 androidboot.usbcontroller=a600000.dwc3 swiotlb=2048 printk.devkmsg=on firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7"

    if [ ! -f "${OUT_KERNEL}" ]; then
        echo "Error: ${OUT_KERNEL} missing! Kernel compilation failed."
        exit 1
    fi

    python3 $MKBOOTIMG \
        --header_version 2 \
        --kernel "$OUT_KERNEL" \
        --ramdisk "$FINAL_RAMDISK" \
        --dtb "$DTB_OUT" \
        --cmdline "$CMDLINE" \
        --base "0x00000000" \
        --kernel_offset "0x00008000" \
        --ramdisk_offset "0x02000000" \
        --second_offset "0x00000000" \
        --dtb_offset "0x01f00000" \
        --tags_offset "0x01e00000" \
        --board "SRPSG08A009" \
        --pagesize "4096" \
        --os_version "16.0.0" \
        --os_patch_level "$MONTH" \
        --output boot.img

    echo "boot.img generated successfully."
}
# Flux de execuție
build_kernel
build_dtb
build_dtbo
build_boot

echo "-----------------------------------------------"
echo "Build process finished successfully!"
echo "-----------------------------------------------"
