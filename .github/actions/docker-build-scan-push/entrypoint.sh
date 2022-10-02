#!/bin/bash

set -eu

echo DOCKER_CONTEXT_DIR: $DOCKER_CONTEXT_DIR
echo DOCKERFILE_NAME: $DOCKERFILE_NAME
echo DOCKER_IMAGE_NAME: $DOCKER_IMAGE_NAME
echo DOCKER_IMAGE_TAG: $DOCKER_IMAGE_TAG
echo DOCKER_BUILD_TYPE: $DOCKER_BUILD_TYPE
echo DOCKERFILE_SCANNER: $DOCKERFILE_SCANNER
echo DOCKER_IMAGE_SCANNER: $DOCKER_IMAGE_SCANNER
echo SCAN_RESULT_DIR: $SCAN_RESULT_DIR
echo STOP_ON_CRITICAL_VULNS: $STOP_ON_CRITICAL_VULNS
echo DOCKER_SBOM_GENERATOR: $DOCKER_SBOM_GENERATOR

mkdir -p $SCAN_RESULT_DIR

### Scan Dockerfile ###
if [ "$DOCKERFILE_SCANNER" == "semgrep" ]; then
    semgrep --config=auto $DOCKER_CONTEXT_DIR/$DOCKERFILE_NAME | tee -a $SCAN_RESULT_DIR/semgrep-dockerfile-$DOCKERFILE_NAME.txt
else
#if [ "$DOCKERFILE_SCANNER" == "trivy" ]; then
    ARGS="-f json -o $SCAN_RESULT_DIR/trivy-dockerfile-$DOCKERFILE_NAME.json $DOCKER_CONTEXT_DIR/$DOCKERFILE_NAME"
    trivy config $ARGS
fi

### Build Docker image ###
if [ "$DOCKER_BUILD_TYPE" == "buildx" ]; then
    echo Building $DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG with buildx
    pushd $DOCKER_CONTEXT_DIR
        docker buildx build -t $DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG . -f $DOCKERFILE_NAME
    popd
fi
if [ "$DOCKER_BUILD_TYPE" == "kaniko" ]; then
    echo Building $DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG with kaniko
    #docker run -v `pwd`/$DOCKER_CONTEXT_DIR:/workspace -v $HOME/.docker/config.json:/kaniko/.docker/config.json:ro gcr.io/kaniko-project/executor:latest --dockerfile /workspace/$DOCKERFILE_NAME --destination $DOCKER_REGISTRY/$GH_ORG/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG --context dir:///workspace/ 
    docker run -v `pwd`/$DOCKER_CONTEXT_DIR:/workspace -v $HOME/.docker/config.json:/kaniko/.docker/config.json:ro gcr.io/kaniko-project/executor:latest --dockerfile /workspace/$DOCKERFILE_NAME --destination $DOCKER_REGISTRY/$GH_ORG/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG --context dir:///workspace/ --tarPath /workspace/$DOCKER_IMAGE_NAME-$DOCKER_IMAGE_TAG.tar --no-push
fi

### Scan Docker image ###
if [ "$DOCKER_IMAGE_SCANNER" == "trivy" ]; then
    ARGS="-f json -o $SCAN_RESULT_DIR/trivy-scan-$DOCKER_IMAGE_NAME-$DOCKER_IMAGE_TAG.json"
    if [ "$STOP_ON_CRITICAL_VULNS" == "true" ]; then
    ARGS="--exit-code 1 --severity CRITICAL $ARGS"
    fi
    if [ "$DOCKER_BUILD_TYPE" == "buildx" ]; then
    ARGS="$ARGS $DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG"
    fi
    if [ "$DOCKER_BUILD_TYPE" == "kaniko" ]; then
    ARGS="$ARGS --input $DOCKER_CONTEXT_DIR/$DOCKER_IMAGE_NAME-$DOCKER_IMAGE_TAG.tar"
    fi
    echo Running: trivy image $ARGS
    trivy image $ARGS
fi
if [ "$DOCKER_IMAGE_SCANNER" == "grype" ]; then
    ARGS="-o json --file $SCAN_RESULT_DIR/grype-scan-$DOCKER_IMAGE_NAME-$DOCKER_IMAGE_TAG.json"
    if [ "$STOP_ON_CRITICAL_VULNS" == "true" ]; then
    ARGS="-f Critical $ARGS"
    fi
    if [ "$DOCKER_BUILD_TYPE" == "buildx" ]; then
    ARGS="$ARGS $DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG"
    fi
    if [ "$DOCKER_BUILD_TYPE" == "kaniko" ]; then
    ARGS="$ARGS $DOCKER_CONTEXT_DIR/$DOCKER_IMAGE_NAME-$DOCKER_IMAGE_TAG.tar"
    fi
    echo Running: grype $ARGS
    grype $ARGS
fi

### Generate SBOM for Docker image
if [ "$DOCKER_SBOM_GENERATOR" == "syft" ]; then
    ARGS="-o json --file $SCAN_RESULT_DIR/syft-sbom-$DOCKER_IMAGE_NAME-$DOCKER_IMAGE_TAG.json packages"
    if [ "$DOCKER_BUILD_TYPE" == "buildx" ]; then
    ARGS="$ARGS $DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG"
    fi
    if [ "$DOCKER_BUILD_TYPE" == "kaniko" ]; then
    ARGS="$ARGS file:$DOCKER_CONTEXT_DIR/$DOCKER_IMAGE_NAME-$DOCKER_IMAGE_TAG.tar"
    fi
    echo Running: syft $ARGS
    syft $ARGS
fi

### Push Docker image to destination registry ###

if [ "$DOCKER_BUILD_TYPE" == "buildx" ]; then
    docker tag $DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG $DOCKER_REGISTRY/$GH_ORG/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG
    docker push $DOCKER_REGISTRY/$GH_ORG/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG
fi
if [ "$DOCKER_BUILD_TYPE" == "kaniko" ]; then
    echo Running: crane push $DOCKER_CONTEXT_DIR/$DOCKER_IMAGE_NAME-$DOCKER_IMAGE_TAG.tar $DOCKER_REGISTRY/$GH_ORG/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG
    crane push $DOCKER_CONTEXT_DIR/$DOCKER_IMAGE_NAME-$DOCKER_IMAGE_TAG.tar $DOCKER_REGISTRY/$GH_ORG/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG
fi

### Sign Docker image with cosign ###

echo -n $COSIGN_KEY_PASSWORD | cosign sign --key $COSIGN_PRIVATE_KEY $DOCKER_REGISTRY/$GH_ORG/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG

### Verify cosign signature ###

cosign verify --key $COSIGN_PUBLIC_KEY $DOCKER_REGISTRY/$GH_ORG/$DOCKER_IMAGE_NAME:$DOCKER_IMAGE_TAG