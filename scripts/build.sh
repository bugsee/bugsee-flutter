#!/usr/bin/env bash


# --------------------------------
echo "Initializing..."
# --------------------------------

WORKSPACE=${WORKSPACE-$PWD}
source ${WORKSPACE}/version.txt
DEPLOY_DIR=${WORKSPACE}/package/
GIT_RESET=false

while getopts "cia" flag
do
    case "${flag}" in
        c) GIT_RESET=true;;
    esac
done


# --------------------------------
echo "Cleaning..."
# --------------------------------

# delete extra files and folders from source directories
rm -rf ./example/ios/.symlinks
rm -rf ./example/ios/Pods
rm -rf $DEPLOY_DIR

if [[ "$GIT_RESET" == true ]]; then
    # clean all
    git reset --hard HEAD
    git clean -fdx
fi


# --------------------------------
echo "Copying assets..."
# --------------------------------

mkdir $DEPLOY_DIR
cd $DEPLOY_DIR

cp -rf ${WORKSPACE}/CHANGELOG.md .
cp -rf ${WORKSPACE}/LICENSE .
cp -rf ${WORKSPACE}/README.md .
cp -rf ${WORKSPACE}/android .
cp -rf ${WORKSPACE}/ios .
cp -rf ${WORKSPACE}/lib .
cp -rf ${WORKSPACE}/example .
cp -rf ${WORKSPACE}/pubspec.yaml .
cp -rf ${WORKSPACE}/analysis_options.yaml .
cp -rf ${WORKSPACE}/.gitignore .


# --------------------------------
echo "Injecting versions..."
# --------------------------------

sed -E -i '' "s/99.99.99/${BUGSEE_PLUGIN_VERSION}/" ./README.md
sed -E -i '' "s/99.99.99/${BUGSEE_PLUGIN_VERSION}/" ./pubspec.yaml
sed -E -i '' "s/99.99.99/${BUGSEE_PLUGIN_VERSION}/" ./lib/src/version.dart
sed -E -i '' "s/99.99.99/${BUGSEE_PLUGIN_VERSION}/" ./ios/bugsee_flutter.podspec
sed -E -i '' "s/99.99.99/${BUGSEE_PLUGIN_VERSION}/" ./android/build.gradle

# put Bugsee iOS SDK version into .podspec file
sed -E -i '' "s/dependency 'Bugsee'/dependency 'Bugsee', '${IOS_VERSION}'/" ./ios/bugsee_flutter.podspec

# put Bugsee Android SDK version into build.gradle
sed -E -i '' "s/bugsee-android:[^']+/bugsee-android:${ANDROID_VERSION}/" ./android/build.gradle

cd -


# --------------------------------
echo "Build completed."
# --------------------------------