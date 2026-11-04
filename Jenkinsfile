pipeline {
    agent any

    parameters {
        string(
            name: 'TAG_TO_DEPLOY',
            defaultValue: '',
            description: 'Release tag to deploy, e.g. v1.0.0. Leave empty when a webhook supplies GIT_REF.'
        )
    }

    environment {
        AWS_REGION = 'ap-southeast-2'
        AWS_ACCOUNT_ID = '741868400311'
        ECR_REPOSITORY = 'unque'
        CODEBUILD_PROJECT = 'unque-build'

        EC2_INSTANCE = 'i-0c6a4dbe7652a8127'
        SSM_PATH = '/unque'
        NGINX_UPSTREAM = '/etc/nginx/conf.d/unque-upstream.conf'
        UPSTREAM_NAME = 'unque_backend'

        HOST_PORT = '3001'
        CONTAINER = 'unque-backend'
        BACKUP_CONTAINER = 'unque-backend-rollback'
        CONTAINER_PORT = '3000'

        ECR_URI = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}"
    }

    stages {
        stage('Validate Release Tag') {
            steps {
                script {
                    def gitRef = (params.TAG_TO_DEPLOY ?: env.RELEASE_TAG ?: env.GIT_REF ?: '').trim()

                    // Allow a bare tag such as v1.0.0 from the build parameter.
                    if (gitRef ==~ /^v[0-9]+\.[0-9]+\.[0-9]+$/) {
                        gitRef = 'refs/tags/' + gitRef
                    }

                    if (!gitRef.startsWith('refs/tags/')) {
                        error('No release tag provided. Set TAG_TO_DEPLOY or RELEASE_TAG (e.g. v1.0.0), or trigger from a Git tag push.')
                    }

                    env.TAG_NAME = gitRef.replace('refs/tags/', '')

                    if (!(env.TAG_NAME ==~ /^v[0-9]+\.[0-9]+\.[0-9]+$/)) {
                        error("Invalid release tag: ${env.TAG_NAME}")
                    }

                    env.DEPLOY_ENV = 'prod'
                    env.CONTAINER_NAME = env.CONTAINER
                    env.BACKUP_CONTAINER_NAME = env.BACKUP_CONTAINER
                    env.IMAGE_TAG = env.TAG_NAME
                    env.RELEASE_TAG = env.TAG_NAME

                    echo "Release Tag: ${env.TAG_NAME}"
                    echo "Environment: PROD"
                    echo "Docker Image: ${env.ECR_URI}:${env.TAG_NAME}"
                }
            }
        }

        stage('Verify AWS Authentication') {
            steps {
                sh '''
                    set -e
                    aws sts get-caller-identity
                '''
            }
        }

        
        stage('Checkout Release Tag') {
            steps {
                checkout scm

                sh '''
                    set -e

                    echo "Fetching release tag: ${TAG_NAME}"

                    git fetch --force --tags origin \
                        "refs/tags/${TAG_NAME}:refs/tags/${TAG_NAME}"

                    git checkout --detach "refs/tags/${TAG_NAME}"

                    EXPECTED_COMMIT=$(git rev-parse "refs/tags/${TAG_NAME}^{commit}")
                    ACTUAL_COMMIT=$(git rev-parse HEAD)

                    if [ "${EXPECTED_COMMIT}" != "${ACTUAL_COMMIT}" ]; then
                        echo "ERROR: Release commit mismatch!"
                        exit 1
                    fi

                    echo "Tag: ${TAG_NAME}"
                    echo "Verified commit: ${ACTUAL_COMMIT}"
                '''
            }
        }

        stage('Production Approval') {
            steps {
                timeout(time: 15, unit: 'MINUTES') {
                    input(
                        message: "Approve deployment of ${env.TAG_NAME} to PRODUCTION?",
                        ok: 'Deploy to Production'
                    )
                }
            }
        }

        stage('Build & Push Image') {
            steps {
                sh '''
                    set -e

                    echo "======================================"
                    echo "STARTING CODEBUILD"
                    echo "Release Tag: ${TAG_NAME}"
                    echo "Environment: PROD"
                    echo "======================================"

                    # Start AWS CodeBuild using the Git release tag
                    BUILD_ID=$(aws codebuild start-build \
                        --project-name "${CODEBUILD_PROJECT}" \
                        --source-version "${TAG_NAME}" \
                        --environment-variables-override \
                            name=IMAGE_TAG,value="${TAG_NAME}",type=PLAINTEXT \
                            name=RELEASE_TAG,value="${TAG_NAME}",type=PLAINTEXT \
                            name=ECR_REPOSITORY,value="${ECR_REPOSITORY}",type=PLAINTEXT \
                            name=ENVIRONMENT,value=prod,type=PLAINTEXT \
                        --region "${AWS_REGION}" \
                        --query 'build.id' \
                        --output text)

                    echo "CodeBuild ID: ${BUILD_ID}"

                    # Wait for CodeBuild completion
                    ATTEMPT=0
                    MAX_ATTEMPTS=120
                    BUILD_STATUS="IN_PROGRESS"

                    while [ "${ATTEMPT}" -lt "${MAX_ATTEMPTS}" ]; do

                        BUILD_STATUS=$(aws codebuild batch-get-builds \
                            --ids "${BUILD_ID}" \
                            --region "${AWS_REGION}" \
                            --query 'builds[0].buildStatus' \
                            --output text)

                        echo "CodeBuild Status: ${BUILD_STATUS}"

                        if [ "${BUILD_STATUS}" = "SUCCEEDED" ]; then
                            echo "CodeBuild completed successfully."
                            break
                        fi

                        case "${BUILD_STATUS}" in
                            FAILED|FAULT|STOPPED|TIMED_OUT)
                                echo "ERROR: CodeBuild failed with status ${BUILD_STATUS}"
                                exit 1
                                ;;
                        esac

                        ATTEMPT=$((ATTEMPT + 1))
                        sleep 15
                    done

                    # Timeout validation
                    if [ "${BUILD_STATUS}" != "SUCCEEDED" ]; then
                        echo "ERROR: CodeBuild timed out after 30 minutes."
                        exit 1
                    fi

                    # Verify Docker image in ECR
                    echo "Verifying ECR image..."

                    aws ecr describe-images \
                        --repository-name "${ECR_REPOSITORY}" \
                        --image-ids imageTag="${TAG_NAME}" \
                        --region "${AWS_REGION}" \
                        --query 'imageDetails[0].imageTags' \
                        --output text

                    echo "======================================"
                    echo "BUILD AND PUSH SUCCESSFUL"
                    echo "Image: ${ECR_URI}:${TAG_NAME}"
                    echo "======================================"
                '''
            }
        }

        
        stage('Deploy to Production') {
            steps {
                script {
                    def registry = env.ECR_URI.split('/')[0]

                    def remoteScript = """#!/bin/bash
        set -Eeuo pipefail

        IMAGE='${env.ECR_URI}:${env.TAG_NAME}'
        AWS_REGION='${env.AWS_REGION}'
        SSM_PATH='${env.SSM_PATH}'
        HOST_PORT='${env.HOST_PORT}'
        CONTAINER_PORT='${env.CONTAINER_PORT}'
        CONTAINER_NAME='${env.CONTAINER_NAME}'
        BACKUP_CONTAINER='${env.BACKUP_CONTAINER_NAME}'
        NGINX_UPSTREAM='${env.NGINX_UPSTREAM}'
        UPSTREAM_NAME='${env.UPSTREAM_NAME}'

        STATE_DIR='/opt/unque/prod'
        ENV_FILE="\${STATE_DIR}/.env"
        NGINX_BACKUP="\${NGINX_UPSTREAM}.jenkins-backup"
        NGINX_TEMP="\${NGINX_UPSTREAM}.jenkins-tmp"

        OLD_CONTAINER_RENAMED=false
        NEW_CONTAINER_STARTED=false
        NGINX_CHANGED=false

        mkdir -p "\${STATE_DIR}"

        # ======================================
        # ROLLBACK FUNCTION
        # ======================================

        rollback() {
            echo "Deployment failed. Starting rollback..."

            if [ "\${NEW_CONTAINER_STARTED}" = true ]; then
                docker rm -f "\${CONTAINER_NAME}" 2>/dev/null || true
            fi

            if [ -f "\${NGINX_BACKUP}" ]; then
                mv "\${NGINX_BACKUP}" "\${NGINX_UPSTREAM}"
                nginx -t && systemctl reload nginx || true
            elif [ "\${NGINX_CHANGED}" = true ]; then
                rm -f "\${NGINX_UPSTREAM}"
                nginx -t && systemctl reload nginx || true
            fi

            if [ "\${OLD_CONTAINER_RENAMED}" = true ] && \
            docker container inspect "\${BACKUP_CONTAINER}" >/dev/null 2>&1; then

                docker rename "\${BACKUP_CONTAINER}" "\${CONTAINER_NAME}" || true
                docker start "\${CONTAINER_NAME}" || true
            fi

            echo "Rollback procedure completed."
        }

        trap rollback ERR

        # ======================================
        # 1. AUTHENTICATE TO AMAZON ECR
        # ======================================

        echo "Authenticating with Amazon ECR..."

        aws ecr get-login-password --region "\${AWS_REGION}" |
            docker login --username AWS --password-stdin '${registry}'
        # ======================================
        # 2. FETCH PRODUCTION ENVIRONMENT
        # ======================================

        echo "Fetching production environment from AWS SSM..."

        aws ssm get-parameters-by-path \
            --region "\${AWS_REGION}" \
            --path "\${SSM_PATH}" \
            --recursive \
            --with-decryption \
            --output json > /tmp/unque-prod-parameters.json

        ENV_FILE="\${ENV_FILE}" python3 -c '
        import json
        import os
        import re

        with open("/tmp/unque-prod-parameters.json") as f:
            data = json.load(f)

        parameters = data.get("Parameters", [])

        if not parameters:
            raise SystemExit("No SSM parameters found under production path")

        with open(os.environ["ENV_FILE"], "w") as f:
            for p in parameters:
                key = p["Name"].split("/")[-1]
                # Tolerate a trailing newline / CRLF (common when values are pasted in).
                value = p["Value"].strip("\\r\\n")

                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
                    raise SystemExit("Invalid environment variable name")

                if "\\n" in value or "\\r" in value:
                    raise SystemExit("Multiline value unsupported for parameter: " + key)

                f.write(f"{key}={value}\\n")
        '

        chmod 600 "\${ENV_FILE}"
        rm -f /tmp/unque-prod-parameters.json

        # ======================================
        # 3. PULL RELEASE IMAGE
        # ======================================

        echo "Pulling production image: \${IMAGE}"

        docker pull "\${IMAGE}"

        # ======================================
        # 4. PRESERVE CURRENT CONTAINER
        # ======================================

        if docker container inspect "\${BACKUP_CONTAINER}" >/dev/null 2>&1; then
            echo "Removing previous rollback container..."
            docker rm -f "\${BACKUP_CONTAINER}"
        fi

        if docker container inspect "\${CONTAINER_NAME}" >/dev/null 2>&1; then
            echo "Preserving current production container..."

            docker stop "\${CONTAINER_NAME}" || true
            docker rename "\${CONTAINER_NAME}" "\${BACKUP_CONTAINER}"

            OLD_CONTAINER_RENAMED=true
        fi

        # ======================================
        # 5. START NEW PRODUCTION CONTAINER
        # ======================================

        echo "Starting new production container..."

        docker run -d \
            --name "\${CONTAINER_NAME}" \
            --restart unless-stopped \
            --env-file "\${ENV_FILE}" \
            -e PORT="\${CONTAINER_PORT}" \
            -p "127.0.0.1:\${HOST_PORT}:\${CONTAINER_PORT}" \
            "\${IMAGE}"

        NEW_CONTAINER_STARTED=true

        # ======================================
        # 6. APPLICATION HEALTH CHECK
        # ======================================

        echo "Checking application health..."

        HEALTHY=false

        for i in \$(seq 1 30); do

            if curl -fsS "http://127.0.0.1:\${HOST_PORT}/health" >/dev/null; then
                HEALTHY=true
                break
            fi

            if ! docker container inspect "\${CONTAINER_NAME}" \
                --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
                echo "Container stopped unexpectedly."
                break
            fi

            sleep 5
        done

        if [ "\${HEALTHY}" != true ]; then
            echo "Application health check failed."
            docker logs "\${CONTAINER_NAME}" || true
            exit 1
        fi

        echo "Application is healthy."

        # ======================================
        # 7. UPDATE NGINX UPSTREAM
        # ======================================

        echo "Updating Nginx upstream..."

        mkdir -p "\$(dirname "\${NGINX_UPSTREAM}")"

        if [ -f "\${NGINX_UPSTREAM}" ]; then
            cp "\${NGINX_UPSTREAM}" "\${NGINX_BACKUP}"
        fi

        printf 'upstream %s {\n    server 127.0.0.1:%s;\n}\n' \
        "\${UPSTREAM_NAME}" \
        "\${HOST_PORT}" > "\${NGINX_TEMP}"

        mv "\${NGINX_TEMP}" "\${NGINX_UPSTREAM}"

        NGINX_CHANGED=true

        # ======================================
        # 8. VALIDATE AND RELOAD NGINX
        # ======================================

        echo "Validating Nginx configuration..."

        nginx -t
        systemctl reload nginx

        # ======================================
        # 9. FINAL PRODUCTION HEALTH CHECK
        # ======================================

        echo "Performing final production health check..."

        curl -fsS "http://127.0.0.1:\${HOST_PORT}/health" >/dev/null

        echo "Production application verified successfully."

        # Deployment is now committed. Disable rollback before cleanup.
        trap - ERR

        # ======================================
        # 10. CLEANUP OLD CONTAINER
        # ======================================

        if [ "\${OLD_CONTAINER_RENAMED}" = true ]; then
            echo "Removing previous production container..."
            docker rm -f "\${BACKUP_CONTAINER}" || true
        fi

        # Remove legacy containers from the previous blue-green deployment.
        docker rm -f unque-backend-prod-blue 2>/dev/null || true
        docker rm -f unque-backend-prod-green 2>/dev/null || true

        rm -f "\${NGINX_BACKUP}" "\${NGINX_TEMP}"

        echo "======================================"
        echo "PRODUCTION DEPLOYMENT SUCCESSFUL"
        echo "======================================"
        echo "Release: \${IMAGE}"
        echo "Container: \${CONTAINER_NAME}"
        echo "Host Port: \${HOST_PORT}"
        echo "Container Port: \${CONTAINER_PORT}"
        echo "======================================"
        """.toString().replaceAll(/(?m)^ {8}/, '')

                    writeFile file: 'deployment-script.sh', text: remoteScript

                    // Encode remote script for SSM execution.
                    sh '''
                        set -e
                        gzip -9 -c deployment-script.sh | base64 -w 0 > deployment-script.b64
                    '''

                    def encodedScript = sh(
                        script: 'cat deployment-script.b64',
                        returnStdout: true
                    ).trim()

                    // SSM command payload must remain within service limits.
                    if (encodedScript.length() > 7000) {
                        error('Deployment script is too large for inline SSM execution. Use an S3-hosted script.')
                    }

                    withEnv(["ENCODED_SCRIPT=${encodedScript}"]) {
                        sh '''
                            set -e

                            python3 -c 'import json, os; print(json.dumps({"commands":["echo " + os.environ["ENCODED_SCRIPT"] + " | base64 -d | gunzip | sudo bash"]}))' \
                                > ssm-parameters.json

                            echo "Sending production deployment command to EC2..."

                            COMMAND_ID=$(aws ssm send-command \
                                --instance-ids "${EC2_INSTANCE}" \
                                --document-name AWS-RunShellScript \
                                --comment "UnQue PROD deployment ${TAG_NAME}" \
                                --parameters file://ssm-parameters.json \
                                --query 'Command.CommandId' \
                                --output text)

                            echo "SSM Command ID: ${COMMAND_ID}"

                            ATTEMPT=0
                            MAX_ATTEMPTS=60
                            STATUS="Pending"

                            while [ "${ATTEMPT}" -lt "${MAX_ATTEMPTS}" ]; do

                                STATUS=$(aws ssm get-command-invocation \
                                    --command-id "${COMMAND_ID}" \
                                    --instance-id "${EC2_INSTANCE}" \
                                    --query 'Status' \
                                    --output text 2>/dev/null || echo "Pending")

                                echo "SSM deployment status: ${STATUS}"

                                case "${STATUS}" in
                                    Success)
                                        echo "Production deployment completed successfully."
                                        break
                                        ;;

                                    Failed|Cancelled|TimedOut|DeliveryTimedOut|ExecutionTimedOut|Undeliverable|Terminated|InvalidPlatform|AccessDenied)
                                        echo "ERROR: SSM deployment failed: ${STATUS}"

                                        aws ssm get-command-invocation \
                                            --region "${AWS_REGION}" \
                                            --command-id "${COMMAND_ID}" \
                                            --instance-id "${EC2_INSTANCE}" \
                                            --query 'StandardErrorContent' \
                                            --output text || true

                                        aws ssm get-command-invocation \
                                            --region "${AWS_REGION}" \
                                            --command-id "${COMMAND_ID}" \
                                            --instance-id "${EC2_INSTANCE}" \
                                            --query 'StandardOutputContent' \
                                            --output text || true

                                        exit 1
                                        ;;
                                esac

                                ATTEMPT=$((ATTEMPT + 1))
                                sleep 10
                            done

                            if [ "${STATUS}" != "Success" ]; then
                                echo "ERROR: Timed out waiting for SSM deployment."
                                exit 1
                            fi
                        '''
                    }

                    // Clean Jenkins workspace temporary files.
                    sh '''
                        rm -f deployment-script.sh \
                            deployment-script.b64 \
                            ssm-parameters.json
                    '''
                }
            }
        }

        stage('Deployment Summary') {
            steps {
                echo "PRODUCTION DEPLOYMENT SUCCESSFUL: ${env.RELEASE_TAG} | ${env.ECR_URI}:${env.IMAGE_TAG} | EC2 ${env.EC2_INSTANCE}"
            }
        }
    }

    post {
        success { echo "Production deployment completed for ${env.RELEASE_TAG}." }
        failure { echo "Production deployment failed for ${env.RELEASE_TAG ?: 'n/a'}. Review Jenkins and SSM command output." }
        always { echo 'Pipeline execution completed.' }
    }
}