
pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(
            daysToKeepStr: '30',
            numToKeepStr: '20'
        ))
        timeout(time: 45, unit: 'MINUTES')
    }

    environment {
        AWS_REGION = 'ap-southeast-2'
        ECR_REPOSITORY = 'unque'
        CODEBUILD_PROJECT = 'unque-build'
        GITHUB_REPOSITORY = 'https://github.com/radspatidar/UnQue-2.0.git'
        BACKEND_HOST = '172.31.14.179'
        BACKEND_USER = 'ubuntu'
        CONTAINER_NAME = 'unque-backend'
        CONTAINER_PORT = '5001'
        HEALTH_PATH = '/health'
    }

    stages {
        stage('Validate Release Event') {
            steps {
                script {
                    def tagRef = env.ref ?: ''

                    if (!(tagRef ==~ /^refs\/tags\/v[0-9]+\.[0-9]+\.[0-9]+$/)) {
                        error("Invalid release tag event: ${tagRef}")
                    }

                    env.RELEASE_TAG = tagRef.replace('refs/tags/', '')

                    if (!env.after || !(env.after ==~ /^[a-fA-F0-9]{40}$/)) {
                        error('Missing or invalid GitHub commit SHA.')
                    }

                    env.RELEASE_COMMIT = env.after

                    echo "Release tag: ${env.RELEASE_TAG}"
                    echo "Release commit: ${env.RELEASE_COMMIT}"
                }
            }
        }

        stage('Checkout Exact Release') {
            steps {
                sh '''
                    set -eu

                    git init .
                    git remote add origin "$GITHUB_REPOSITORY"

                    git fetch --no-tags origin \
                      "refs/tags/${RELEASE_TAG}:refs/tags/${RELEASE_TAG}"

                    git checkout --detach "refs/tags/${RELEASE_TAG}"

                    ACTUAL_COMMIT=$(git rev-parse HEAD)

                    test "$ACTUAL_COMMIT" = "$RELEASE_COMMIT"

                    echo "Checked out exact release commit: $ACTUAL_COMMIT"
                '''
            }
        }

        stage('Validate AWS Access') {
            steps {
                sh '''
                    set -eu

                    aws --version
                    aws sts get-caller-identity
                '''
            }
        }

        stage('Trigger AWS CodeBuild') {
            steps {
                script {
                    env.CODEBUILD_BUILD_ID = sh(
                        script: '''
                            aws codebuild start-build \
                              --project-name "$CODEBUILD_PROJECT" \
                              --source-version "$RELEASE_COMMIT" \
                              --region "$AWS_REGION" \
                              --environment-variables-override \
                                name=RELEASE_TAG,value="$RELEASE_TAG",type=PLAINTEXT \
                              --query 'build.id' \
                              --output text
                        ''',
                        returnStdout: true
                    ).trim()

                    if (!env.CODEBUILD_BUILD_ID ||
                        env.CODEBUILD_BUILD_ID == 'None') {
                        error('Unable to start CodeBuild.')
                    }

                    echo "CodeBuild ID: ${env.CODEBUILD_BUILD_ID}"
                }
            }
        }

        stage('Wait for CodeBuild') {
            steps {
                script {
                    timeout(time: 30, unit: 'MINUTES') {
                        waitUntil {
                            def status = sh(
                                script: """
                                    aws codebuild batch-get-builds \
                                      --ids '${env.CODEBUILD_BUILD_ID}' \
                                      --region '${env.AWS_REGION}' \
                                      --query 'builds[0].buildStatus' \
                                      --output text
                                """,
                                returnStdout: true
                            ).trim()

                            echo "CodeBuild status: ${status}"

                            if (status == 'SUCCEEDED') {
                                return true
                            }

                            if (['FAILED', 'FAULT', 'STOPPED',
                                 'TIMED_OUT'].contains(status)) {
                                error("CodeBuild failed: ${status}")
                            }

                            sleep(time: 15, unit: 'SECONDS')
                            return false
                        }
                    }
                }
            }
        }

        stage('Deploy to Backend EC2') {
            steps {
                sshagent(credentials: ['server-1-ssh-key']) {
                    sh '''
                        set -eu

                        ssh -o BatchMode=yes \
                            -o StrictHostKeyChecking=yes \
                            "$BACKEND_USER@$BACKEND_HOST" \
                            "bash -s" <<'REMOTE_SCRIPT'

                        set -euo pipefail

                        AWS_REGION="ap-southeast-2"
                        ECR_REPOSITORY="unque"
                        RELEASE_TAG="''' + env.RELEASE_TAG + '''"
                        CONTAINER_NAME="unque-backend"
                        CONTAINER_PORT="5001"
                        HEALTH_PATH="/health"
                        ENV_FILE="/opt/unque/.env"

                        test -s "$ENV_FILE"

                        AWS_ACCOUNT_ID=$(aws sts get-caller-identity \
                            --query Account --output text)

                        ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
                        IMAGE_URI="${ECR_REGISTRY}/${ECR_REPOSITORY}:${RELEASE_TAG}"

                        aws ecr get-login-password --region "$AWS_REGION" |
                            docker login --username AWS --password-stdin "$ECR_REGISTRY"

                        docker pull "$IMAGE_URI"

                        # Start candidate on a temporary local port.
                        docker rm -f unque-backend-candidate 2>/dev/null || true

                        docker run -d \
                            --name unque-backend-candidate \
                            --restart unless-stopped \
                            --env-file "$ENV_FILE" \
                            -p 127.0.0.1:15001:5001 \
                            "$IMAGE_URI"

                        # Verify candidate before replacing the current container.
                        HEALTHY=0

                        for attempt in $(seq 1 24); do
                            if curl --fail --silent \
                                "http://127.0.0.1:15001${HEALTH_PATH}" >/dev/null; then
                                HEALTHY=1
                                break
                            fi
                            sleep 5
                        done

                        if [ "$HEALTHY" -ne 1 ]; then
                            docker logs unque-backend-candidate || true
                            docker rm -f unque-backend-candidate || true
                            echo "Candidate health check failed."
                            exit 1
                        fi

                        # Save previous image for rollback.
                        PREVIOUS_IMAGE=""

                        if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
                            PREVIOUS_IMAGE=$(docker inspect \
                                --format '{{.Config.Image}}' "$CONTAINER_NAME")
                            docker rm -f "$CONTAINER_NAME"
                        fi

                        docker rm -f unque-backend-candidate

                        # Start the release on the application port.
                        if ! docker run -d \
                            --name "$CONTAINER_NAME" \
                            --restart unless-stopped \
                            --env-file "$ENV_FILE" \
                            -p 127.0.0.1:${CONTAINER_PORT}:5001 \
                            "$IMAGE_URI"; then

                            if [ -n "$PREVIOUS_IMAGE" ]; then
                                docker run -d \
                                    --name "$CONTAINER_NAME" \
                                    --restart unless-stopped \
                                    --env-file "$ENV_FILE" \
                                    -p 127.0.0.1:${CONTAINER_PORT}:5001 \
                                    "$PREVIOUS_IMAGE"
                            fi

                            exit 1
                        fi

                        # Verify the newly deployed container.
                        HEALTHY=0

                        for attempt in $(seq 1 24); do
                            if curl --fail --silent \
                                "http://127.0.0.1:${CONTAINER_PORT}${HEALTH_PATH}" >/dev/null; then
                                HEALTHY=1
                                break
                            fi
                            sleep 5
                        done

                        if [ "$HEALTHY" -ne 1 ]; then
                            docker logs "$CONTAINER_NAME" || true
                            docker rm -f "$CONTAINER_NAME" || true

                            if [ -n "$PREVIOUS_IMAGE" ]; then
                                docker run -d \
                                    --name "$CONTAINER_NAME" \
                                    --restart unless-stopped \
                                    --env-file "$ENV_FILE" \
                                    -p 127.0.0.1:${CONTAINER_PORT}:5001 \
                                    "$PREVIOUS_IMAGE"
                                echo "Previous image restored."
                            fi

                            exit 1
                        fi

                        echo "Deployment and health check successful."
                        docker ps --filter "name=$CONTAINER_NAME"

                        REMOTE_SCRIPT
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "Successfully deployed ${env.RELEASE_TAG}"
        }

        failure {
            echo 'Pipeline failed. Review Jenkins and CodeBuild logs.'
        }

        always {
            echo 'UnQue deployment pipeline finished.'
        }
    }
}
