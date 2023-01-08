export PATH=$PATH:/usr/local/bin

source ./version.txt

WORKSPACE=${WORKSPACE-$PWD}
DEPLOY_DIR=${WORKSPACE}/package/

cd $DEPLOY_DIR

# make dry run first to check whether assembled package 
# has any publishing issues
dart pub publish --dry-run --verbose

if [ ${RELEASE-false} == true ]
then
    # PROD: publish built artifacts to the NPM registry
    dart pub publish --force --verbose
fi

cd -
