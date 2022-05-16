export PATH=$PATH:/usr/local/bin

source ./version.txt

WORKSPACE=${WORKSPACE-$PWD}
DEPLOY_DIR=${WORKSPACE}/deploy/

rm -rf ./example/ios/.symlinks
rm -rf ./example/ios/Pods
rm -rf $DEPLOY_DIR
git clone ssh://git@github.com/bugsee/flutter-bugsee $DEPLOY_DIR
rm -rf $DEPLOY_DIR/*
cd $DEPLOY_DIR

cp -rf ${WORKSPACE}/CHANGELOG.md .
cp -rf ${WORKSPACE}/LICENSE .
cp -rf ${WORKSPACE}/README.md .
cp -rf ${WORKSPACE}/android .
cp -rf ${WORKSPACE}/example .
cp -rf ${WORKSPACE}/ios .
cp -rf ${WORKSPACE}/lib .
cp -rf ${WORKSPACE}/pubspec.yaml .
cp -rf ${WORKSPACE}/.gitignore .

# update wrapper version
sed -E -i '' "s/99.99.99/${BUGSEE_PLUGIN_VERSION}/" ./pubspec.yaml
sed -E -i '' "s/99.99.99/${BUGSEE_PLUGIN_VERSION}/" ./lib/src/version.dart
sed -E -i '' "s/99.99.99/${BUGSEE_PLUGIN_VERSION}/" ./ios/bugsee_flutter.podspec
sed -E -i '' "s/99.99.99/${BUGSEE_PLUGIN_VERSION}/" ./android/build.gradle

# put Bugsee iOS SDK version into .podspec file
sed -E -i '' "s/dependency 'Bugsee'/dependency 'Bugsee', '${IOS_VERSION}'/" ./ios/bugsee_flutter.podspec

# put Bugsee Android SDK version into build.gradle
sed -E -i '' "s/bugsee-android:[^']+/bugsee-android:${ANDROID_VERSION}/" ./android/build.gradle


git add .

git commit -m "Updating SDK to $BUGSEE_PLUGIN_VERSION"
git push -f origin HEAD:refs/heads/master
git push -f origin HEAD:refs/tags/$BUGSEE_PLUGIN_VERSION
cd -
