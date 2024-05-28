#! /bin/sh

set -e

FLUTTER_INSTALL_PATH=${1:-~/}

echo "Installing dependencies..."

sudo apt-get update -y && sudo apt-get upgrade -y;
sudo apt-get install -y curl git unzip xz-utils zip libglu1-mesa
sudo apt-get install \
      clang cmake git \
      ninja-build pkg-config \
      libgtk-3-dev liblzma-dev \
      libstdc++-12-dev

echo "Downloading flutter 3.19..."

wget -N https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.19.0-stable.tar.xz

[ -d $FLUTTER_INSTALL_PATH/. ] || mkdir $FLUTTER_INSTALL_PATH

tar -xf flutter_linux_3.19.0-stable.tar.xz \
     -C $FLUTTER_INSTALL_PATH

echo "#########################"
echo "Add flutter to your path."
echo "PATH=$FLUTTER_INSTALL_PATH/flutter/bin:\$PATH"
echo "#########################"
echo "Installing flutterpi_tool"
$FLUTTER_INSTALL_PATH/flutter/bin/dart pub global activate flutterpi_tool 0.3.0
echo "Cleaning up..."
rm flutter_linux_3.19.0-stable.tar.xz
