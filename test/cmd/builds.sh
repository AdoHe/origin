#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

OS_ROOT=$(dirname "${BASH_SOURCE}")/../..
source "${OS_ROOT}/hack/util.sh"
source "${OS_ROOT}/hack/cmd_util.sh"
source "${OS_ROOT}/hack/lib/test/junit.sh"
os::log::install_errexit
trap os::test::junit::reconcile_output EXIT

# Cleanup cluster resources created by this test
(
  set +e
  oc delete all,templates --all
  exit 0
) &>/dev/null


url=":${API_PORT:-8443}"
project="$(oc project -q)"

os::test::junit::declare_suite_start "cmd/builds"
# This test validates builds and build related commands

os::cmd::expect_success 'oc new-build centos/ruby-22-centos7 https://github.com/openshift/ruby-hello-world.git'
os::cmd::expect_success 'oc get bc/ruby-hello-world'
os::cmd::expect_success 'cat "${OS_ROOT}/Dockerfile" | oc new-build -D - --name=test'
os::cmd::expect_success 'oc get bc/test'

template='{{with .spec.output.to}}{{.kind}} {{.name}}{{end}}'

# Build from Dockerfile with output to ImageStreamTag
os::cmd::expect_success "oc new-build --dockerfile=\$'FROM centos:7\nRUN yum install -y httpd'"
os::cmd::expect_success_and_text "oc get bc/centos --template '${template}'" '^ImageStreamTag centos:latest$'

# Build from a binary with no inputs requires name
os::cmd::expect_failure_and_text "oc new-build --binary" "you must provide a --name"

# Build from a binary with inputs creates a binary build
os::cmd::expect_success "oc new-build --binary --name=binary-test"
os::cmd::expect_success_and_text "oc get bc/binary-test" 'Binary'

os::cmd::expect_success 'oc delete is/binary-test bc/binary-test'

# Build from Dockerfile with output to DockerImage
os::cmd::expect_success "oc new-build -D \$'FROM openshift/origin:v1.1' --to-docker"
os::cmd::expect_success_and_text "oc get bc/origin --template '${template}'" '^DockerImage origin:latest$'

os::cmd::expect_success 'oc delete is/origin'

# Build from Dockerfile with given output ImageStreamTag spec
os::cmd::expect_success "oc new-build -D \$'FROM openshift/origin:v1.1\nENV ok=1' --to origin-test:v1.1"
os::cmd::expect_success_and_text "oc get bc/origin-test --template '${template}'" '^ImageStreamTag origin-test:v1.1$'

os::cmd::expect_success 'oc delete is/origin bc/origin'

# Build from Dockerfile with given output DockerImage spec
os::cmd::expect_success "oc new-build -D \$'FROM openshift/origin:v1.1\nENV ok=1' --to-docker --to openshift/origin:v1.1-test"
os::cmd::expect_success_and_text "oc get bc/origin --template '${template}'" '^DockerImage openshift/origin:v1.1-test$'

os::cmd::expect_success 'oc delete is/origin'

# Build from Dockerfile with custom name and given output ImageStreamTag spec
os::cmd::expect_success "oc new-build -D \$'FROM openshift/origin:v1.1\nENV ok=1' --to origin-name-test --name origin-test2"
os::cmd::expect_success_and_text "oc get bc/origin-test2 --template '${template}'" '^ImageStreamTag origin-name-test:latest$'

os::cmd::try_until_text 'oc get is ruby-22-centos7' 'latest'
os::cmd::expect_failure_and_text 'oc new-build ruby-22-centos7~https://github.com/openshift/ruby-ex ruby-22-centos7~https://github.com/openshift/ruby-ex --to invalid/argument' 'error: only one component with source can be used when specifying an output image reference'

os::cmd::expect_success 'oc delete all --all'

os::cmd::expect_success "oc new-build -D \$'FROM centos:7' --no-output"
os::cmd::expect_success_and_text 'oc get bc/centos -o=jsonpath="{.spec.output.to}"' '^<nil>$'

# Ensure output is valid JSON
os::cmd::expect_success 'oc new-build -D "FROM centos:7" -o json | python -m json.tool'

os::test::junit::declare_suite_start "cmd/builds/postcommithook"
# Ensure post commit hook is executed
os::cmd::expect_success 'oc new-build -D "FROM busybox:1"'
os::cmd::try_until_text 'oc get istag busybox:1' 'busybox@sha256:'
os::cmd::expect_success 'oc patch bc/busybox -p '\''{"spec":{"postCommit":{"script":"echo hello $1","args":["world"],"command":null}}}'\'
os::cmd::expect_success_and_text 'oc get bc/busybox -o=jsonpath="{.spec.postCommit['\''script'\'','\''args'\'','\''command'\'']}"' '^echo hello \$1 \[world\] \[\]$'
# os::cmd::expect_success_and_text 'oc start-build --wait --follow busybox' 'hello world'
os::cmd::expect_success 'oc patch bc/busybox -p '\''{"spec":{"postCommit":{"command":["sh","-c"],"args":["echo explicit command"],"script":""}}}'\'
os::cmd::expect_success_and_text 'oc get bc/busybox -o=jsonpath="{.spec.postCommit['\''script'\'','\''args'\'','\''command'\'']}"' ' \[echo explicit command\] \[sh -c\]'
# os::cmd::expect_success_and_text 'oc start-build --wait --follow busybox' 'explicit command'
os::cmd::expect_success 'oc patch bc/busybox -p '\''{"spec":{"postCommit":{"args":["echo","default entrypoint"],"command":null,"script":""}}}'\'
os::cmd::expect_success_and_text 'oc get bc/busybox -o=jsonpath="{.spec.postCommit['\''script'\'','\''args'\'','\''command'\'']}"' ' \[echo default entrypoint\] \[\]'
# os::cmd::expect_success_and_text 'oc start-build --wait --follow busybox' 'default entrypoint'
echo "postCommitHook: ok"
os::test::junit::declare_suite_end

os::cmd::expect_success 'oc delete all --all'
os::cmd::expect_success 'oc process -f examples/sample-app/application-template-dockerbuild.json -l build=docker | oc create -f -'
os::cmd::expect_success 'oc get buildConfigs'
os::cmd::expect_success 'oc get bc'
os::cmd::expect_success 'oc get builds'

# make sure the imagestream has the latest tag before trying to test it or start a build with it
os::cmd::try_until_text 'oc get is ruby-22-centos7' 'latest'

os::test::junit::declare_suite_start "cmd/builds/patch-anon-fields"
REAL_OUTPUT_TO=$(oc get bc/ruby-sample-build --template='{{ .spec.output.to.name }}')
os::cmd::expect_success "oc patch bc/ruby-sample-build -p '{\"spec\":{\"output\":{\"to\":{\"name\":\"different:tag1\"}}}}'"
os::cmd::expect_success_and_text "oc get bc/ruby-sample-build --template='{{ .spec.output.to.name }}'" 'different'
os::cmd::expect_success "oc patch bc/ruby-sample-build -p '{\"spec\":{\"output\":{\"to\":{\"name\":\"${REAL_OUTPUT_TO}\"}}}}'"
echo "patchAnonFields: ok"
os::test::junit::declare_suite_end

os::test::junit::declare_suite_start "cmd/builds/config"
os::cmd::expect_success_and_text 'oc describe buildConfigs ruby-sample-build' "${url}/oapi/v1/namespaces/${project}/buildconfigs/ruby-sample-build/webhooks/secret101/github"
os::cmd::expect_success_and_text 'oc describe buildConfigs ruby-sample-build' "Webhook GitHub"
os::cmd::expect_success_and_text 'oc describe buildConfigs ruby-sample-build' "${url}/oapi/v1/namespaces/${project}/buildconfigs/ruby-sample-build/webhooks/secret101/generic"
os::cmd::expect_success_and_text 'oc describe buildConfigs ruby-sample-build' "Webhook Generic"
os::cmd::expect_success 'oc start-build --list-webhooks='all' ruby-sample-build'
os::cmd::expect_success_and_text 'oc start-build --list-webhooks=all bc/ruby-sample-build' 'generic'
os::cmd::expect_success_and_text 'oc start-build --list-webhooks=all ruby-sample-build' 'github'
os::cmd::expect_success_and_text 'oc start-build --list-webhooks=github ruby-sample-build' 'secret101'
os::cmd::expect_failure 'oc start-build --list-webhooks=blah'
webhook=$(oc start-build --list-webhooks='generic' ruby-sample-build --api-version=v1 | head -n 1)
os::cmd::expect_success "oc start-build --from-webhook=${webhook}"
os::cmd::expect_success 'oc get builds'
os::cmd::expect_success 'oc delete all -l build=docker'
echo "buildConfig: ok"
os::test::junit::declare_suite_end

os::test::junit::declare_suite_start "cmd/builds/setbuildhook"
# Validate the set build-hook command
arg="-f test/testdata/test-bc.yaml"
os::cmd::expect_failure_and_text "oc set build-hook" "error: one or more build configs"
os::cmd::expect_failure_and_text "oc set build-hook ${arg}" "error: you must specify a type of hook"
os::cmd::expect_success_and_text "oc set build-hook ${arg} --post-commit -o yaml -- echo 'hello world'" 'postCommit:'
os::cmd::expect_success_and_text "oc set build-hook ${arg} --post-commit -o yaml -- echo 'hello world'" 'args:'
os::cmd::expect_success_and_text "oc set build-hook ${arg} --post-commit -o yaml -- echo 'hello world'" '\- echo'
os::cmd::expect_success_and_text "oc set build-hook ${arg} --post-commit -o yaml -- echo 'hello world'" '\- hello world'
os::cmd::expect_success_and_not_text "oc set build-hook ${arg} --post-commit -o yaml -- echo 'hello world'" 'command:'
os::cmd::expect_success_and_text "oc set build-hook ${arg} --post-commit --command -o yaml -- echo 'hello world'" 'command:'
os::cmd::expect_success_and_text "oc set build-hook ${arg} --post-commit -o yaml --script='echo \"hello world\"'" 'script: echo \"hello world\"'
# Server object tests
os::cmd::expect_success "oc create -f test/testdata/test-bc.yaml"
os::cmd::expect_failure_and_text "oc set build-hook bc/test-buildconfig --post-commit" "you must specify either a script or command"
os::cmd::expect_success_and_text "oc set build-hook test-buildconfig --post-commit -- echo 'hello world'" "updated"
os::cmd::expect_success_and_text "oc set build-hook bc/test-buildconfig --post-commit -- echo 'hello world'" "was not changed"
os::cmd::expect_success_and_text "oc get bc/test-buildconfig -o yaml" "args:"
os::cmd::expect_success_and_text "oc set build-hook bc/test-buildconfig --post-commit --command -- /bin/bash -c \"echo 'test'\"" "updated"
os::cmd::expect_success_and_text "oc get bc/test-buildconfig -o yaml" "command:"
os::cmd::expect_success_and_text "oc set build-hook --all --post-commit -- echo 'all bc'" "updated"
os::cmd::expect_success_and_text "oc get bc -o yaml" "all bc"
os::cmd::expect_success_and_text "oc set build-hook bc/test-buildconfig --post-commit --remove" "updated"
os::cmd::expect_success_and_not_text "oc get bc/test-buildconfig -o yaml" "args:"
os::cmd::expect_success "oc delete bc/test-buildconfig"
echo "set build-hook: ok"
os::test::junit::declare_suite_end

os::test::junit::declare_suite_start "cmd/builds/start-build"
os::cmd::expect_success 'oc create -f test/integration/testdata/test-buildcli.json'
# a build for which there is not an upstream tag in the corresponding imagerepo, so
# the build should use the image field as defined in the buildconfig
started=$(oc start-build ruby-sample-build-invalidtag)
os::cmd::expect_success_and_text "oc describe build ${started}" 'centos/ruby-22-centos7$'
frombuild=$(oc start-build --from-build="${started}")
os::cmd::expect_success_and_text "oc describe build ${frombuild}" 'centos/ruby-22-centos7$'
echo "start-build: ok"
os::test::junit::declare_suite_end

os::test::junit::declare_suite_start "cmd/builds/cancel-build"
os::cmd::expect_success_and_text "oc cancel-build ${started} --dump-logs --restart" "restarted build \"${started}\""
os::cmd::expect_success 'oc delete all --all'
os::cmd::expect_success 'oc process -f examples/sample-app/application-template-dockerbuild.json -l build=docker | oc create -f -'
os::cmd::try_until_success 'oc get build/ruby-sample-build-1'
# Uses type/name resource syntax to cancel the build and check for proper message
os::cmd::expect_success_and_text 'oc cancel-build build/ruby-sample-build-1' 'build "ruby-sample-build-1" cancelled'
# Make sure canceling already cancelled build returns proper message
os::cmd::expect_success 'oc cancel-build build/ruby-sample-build-1'
# Cancel all builds from a build configuration
os::cmd::expect_success "oc start-build bc/ruby-sample-build"
os::cmd::expect_success "oc start-build bc/ruby-sample-build"
lastbuild=$(oc start-build bc/ruby-sample-build)
os::cmd::expect_success_and_text 'oc cancel-build bc/ruby-sample-build', "build \"${lastbuild}\" cancelled"
os::cmd::expect_success_and_text "oc get builds ${lastbuild} -o template --template '{{.status.phase}}'", 'Cancelled'
builds=$(oc get builds -o template --template '{{range .items}}{{ .status.phase }} {{end}}')
for state in $builds; do
  os::cmd::expect_success "[ \"${state}\" == \"Cancelled\" ]"
done
# Running this command again when all builds are cancelled should be no-op.
os::cmd::expect_success 'oc cancel-build bc/ruby-sample-build'
os::cmd::expect_success 'oc delete all --all'
echo "cancel-build: ok"
os::test::junit::declare_suite_end

os::test::junit::declare_suite_end
