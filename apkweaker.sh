#!/bin/bash

set -e
echo -e "\033[32m █████╗ ██████╗ ██╗  ██╗██╗    █\033[34m█╗███████╗ █████╗ ██╗  ██╗███████╗██████╗ \033[0m"
echo -e "\033[32m██╔══██╗██╔══██╗██║ ██╔╝██║    \033[34m██║██╔════╝██╔══██╗██║ ██╔╝██╔════╝██╔══██╗\033[0m"
echo -e "\033[32m███████║██████╔╝█████╔╝ \033[34m██║ █╗ ██║█████╗  ███████║█████╔╝ █████╗  ██████╔╝\033[0m"
echo -e "\033[32m██╔══██║██╔═══╝ ██╔═██╗ \033[34m██║███╗██║██╔══╝  ██╔══██║██╔═██╗ ██╔══╝  ██╔══██╗\033[0m"
echo -e "\033[32m██║  ██║██║     ██║  ██╗\033[34m╚███╔███╔╝███████╗██║  ██║██║  ██╗███████╗██║  ██║\033[0m"
echo -e "\033[32m╚═╝  ╚═╝╚═╝     ╚═╝  ╚═╝ \033[34m╚══╝╚══╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝\033[0m"
echo -e "\033[31m                Author: \033[34mMohammed Khalid\033[0m"

# Define constants
read -p "[+] Enter The Package Name / com.ex.app: " PACKAGE_NAME
read -p "[+] Enter The Serial Emulator / adb devices: " EMULATOR_SERIAL
APKTOOL_JAR="$(pwd)/requirements/apktool_2.11.1.jar"
UBER_SIGNER_JAR="$(pwd)/requirements/uber-apk-signer-1.3.0.jar"
BASE_DIR="$(pwd)/$PACKAGE_NAME"

# Define directories
DECOMPILE_DIR="$BASE_DIR/Updated_Decompile"
DECOMPILE_BACKUP_DIR="$BASE_DIR/Original_Decompile"
APKS_DIR="$BASE_DIR/Original_APKs"
BUILD_DIR="$BASE_DIR/Updated_APKs"
SIGNED_APKS_DIR="$BASE_DIR/Signed_APKs"
SIGNED_KEYS_DIR="$BASE_DIR/Signed_Keys"

# Function to check and install dependencies
check_and_install() {
    local cmd=$1
    local pkg=$2
    if ! command -v "$cmd" &>/dev/null; then
        echo "[+] $cmd is not installed. Installing $pkg . . ."
        if command -v apt &>/dev/null; then
            sudo apt update && sudo apt install -y "$pkg"
        else
            echo "[-] Error: Package Manager 'apt' Not Found, Please Install $pkg Manually"
            exit 1
        fi
    else
        echo "[-] $cmd is Already installed"
    fi
}

check_and_install adb adb
check_and_install java openjdk-17-jdk
check_and_install xmlstarlet xmlstarlet

for jar in "$APKTOOL_JAR" "$UBER_SIGNER_JAR"; do
    if [ ! -f "$jar" ]; then
        echo "Error: $jar Not Found"
        exit 1
    fi
done

for dir in "$DECOMPILE_DIR" "$DECOMPILE_BACKUP_DIR" "$APKS_DIR" "$BUILD_DIR" "$SIGNED_APKS_DIR" "$SIGNED_KEYS_DIR"; do
    mkdir -p "$dir" || { echo "[-] Error: Failed to create $dir"; exit 1; }
done

# Pull APKs from emulator
echo "[+] Pulling APKs for $PACKAGE_NAME from emulator $EMULATOR_SERIAL . . ."
adb -s "$EMULATOR_SERIAL" shell pm path "$PACKAGE_NAME" | cut -d ":" -f2 | while read -r apk_path; do
    filename=$(basename "$apk_path")
    adb -s "$EMULATOR_SERIAL" pull "$apk_path" "$APKS_DIR/$filename" || {
        echo "[-] Error: Failed to pull $apk_path"
        exit 1
    }
done

if [ -z "$(ls -A "$APKS_DIR")" ]; then
    echo "[-] Error: No APKs Were Pulled To $APKS_DIR"
    exit 1
fi
echo "[+] All Split APKs Downloaded to $APKS_DIR"

# Decompile APKs
for apk in "$APKS_DIR"/*.apk; do
    if [ -f "$apk" ]; then
        filename=$(basename "$apk" .apk)
        echo "Decompiling $apk . . ."
        java -jar "$APKTOOL_JAR" d "$apk" -o "$DECOMPILE_DIR/$filename" --force || {
            echo "[-] Error: Failed to decompile $apk"
            exit 1
        }
    else
        echo "[-] Error: No APKs Found In $APKS_DIR"
        exit 1
    fi
done

# Backup the Decompile directory before modifications
echo "[+] 📁 Creating backup of $DECOMPILE_DIR to $DECOMPILE_BACKUP_DIR . . ."
cp -r "$DECOMPILE_DIR" "$DECOMPILE_BACKUP_DIR" || {
    echo "[-] Error: Failed to create backup of $DECOMPILE_DIR"
    exit 1
}
echo "[+] ✅ Backup created in $DECOMPILE_BACKUP_DIR"

# Inject networkSecurityConfig attribute *only* for the base APK
# Assuming base APK folder contains "base" or matches PACKAGE_NAME
find "$DECOMPILE_DIR" -type d \( -name "*base*" -o -name "$PACKAGE_NAME" \) -print0 | while IFS= read -r -d $'\0' dir; do
    manifest="$dir/AndroidManifest.xml"
    if [ -f "$manifest" ]; then
        if xmlstarlet sel -t -v "//application/@android:networkSecurityConfig" "$manifest" 2>/dev/null | grep -q .; then
            echo "[+] Already has 'networkSecurityConfig' in $manifest, Skipping"
            continue
        fi
        xmlstarlet ed --inplace \
            -N android="http://schemas.android.com/apk/res/android" \
            -i "/manifest/application" \
            -t attr -n "android:networkSecurityConfig" -v "@xml/network_security_config" \
            "$manifest" || {
                echo "[-] Error: Failed To Update $manifest"
                exit 1
            }
        echo "[+] ✔️ Updated: '$manifest'"
    else
        echo "[-] Warning: 'AndroidManifest.xml' Not Found In $dir, Skipping"
    fi
done

# Create or update network security configuration *only* for the base APK
find "$DECOMPILE_DIR" -type d \( -name "*base*" -o -name "$PACKAGE_NAME" \) -print0 | while IFS= read -r -d $'\0' dir; do
    if [ -d "$dir" ]; then
        xml_dir="$dir/res/xml"
        config_file="$xml_dir/network_security_config.xml"
        mkdir -p "$xml_dir" || { echo "Error: Failed to create $xml_dir"; exit 1; }
        if [ ! -f "$config_file" ]; then
            echo "📄 Creating new: '$config_file'"
            cat <<EOF > "$config_file"
<network-security-config>
    <base-config cleartextTrafficPermitted="true">
        <trust-anchors>
            <certificates src="user"/>
            <certificates src="system"/>
        </trust-anchors>
    </base-config>
</network-security-config>
EOF
        else
            echo "🛠️ Updating existing: $config_file"
            xmlstarlet ed --inplace \
                -d "//base-config" \
                -s "/network-security-config" -t elem -n "base-config" -v "" \
                -i "/network-security-config/base-config" -t attr -n "cleartextTrafficPermitted" -v "true" \
                -s "/network-security-config/base-config" -t elem -n "trust-anchors" -v "" \
                -s "/network-security-config/base-config/trust-anchors" -t elem -n "certificates" -v "" \
                -i "//certificates[1]" -t attr -n "src" -v "user" \
                -s "/network-security-config/base-config/trust-anchors" -t elem -n "certificates" -v "" \
                -i "//certificates[2]" -t attr -n "src" -v "system" \
                "$config_file" || {
                    echo "Error: Failed to update $config_file"
                    exit 1
                }
        fi
    fi
done

# Build APKs with aapt2 to ensure resources.arsc is uncompressed and aligned
if [ -z "$(ls -A "$DECOMPILE_DIR")" ]; then
    echo "[-] Error: No Decompiled APKs Found in $DECOMPILE_DIR"
    exit 1
fi
for dir in "$DECOMPILE_DIR"/*; do
    if [ -d "$dir" ]; then
        filename=$(basename "$dir")
        echo "🔨 Building $filename.apk with aapt2 . . ."
        java -jar "$APKTOOL_JAR" b "$dir" -o "$BUILD_DIR/$filename.apk" --use-aapt2 || {
            echo "Error: Failed to build $filename.apk"
            exit 1
        }
    fi
done
echo "✅ Done building all APKs . . ."

# Sign APKs
if [ -z "$(ls -A "$BUILD_DIR"/*.apk 2>/dev/null)" ]; then
    echo "Error: No APKs found in $BUILD_DIR to sign."
    exit 1
fi
echo "🔏 Signing APKs in $BUILD_DIR..."
java -jar "$UBER_SIGNER_JAR" --apks "$BUILD_DIR" || {
    echo "Error: Failed to sign APKs"
    exit 1
}


echo "Moving Signed APKs To $SIGNED_APKS_DIR . . ."
find "$BUILD_DIR" -name "*-aligned-debugSigned.apk" -exec mv {} "$SIGNED_APKS_DIR/" \; || {
    echo "Error: No Signed APKs Found Or Failed To Move Them"
    exit 1
}
echo "Moving '.idsig' Files To $SIGNED_KEYS_DIR . . ."
find "$BUILD_DIR" -name "*-aligned-debugSigned.apk.idsig" -exec mv {} "$SIGNED_KEYS_DIR/" \; || {
    echo "Warning: No '.idsig' Files Found Or Failed To Move Them"
}

# Install APKs on emulator (commented out as in original script)
# echo "📲 Installing APKs on emulator $EMULATOR_SERIAL . . ."
# adb -s "$EMULATOR_SERIAL" install-multiple "$SIGNED_APKS_DIR"/*.apk || {
#     echo "Error: Failed to install APKs"
#     exit 1
# }
# echo "✅ APKs installed successfully."

echo "✅ Done. Signed APKs are in: $SIGNED_APKS_DIR"
echo "✅ Done. Signed keys are in: $SIGNED_KEYS_DIR"
echo "[+] Now Install All Split APK's On Emulator, Using: 'adb install-multiple "$SIGNED_APKS_DIR"/*.apk'"
