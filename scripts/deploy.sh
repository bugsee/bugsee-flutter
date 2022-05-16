export PATH=$PATH:/usr/local/bin

source ./version.txt

WORKSPACE=${WORKSPACE-$PWD}
DEPLOY_DIR=${WORKSPACE}/package/

cd $DEPLOY_DIR

dart pub publish

cd -
