#!/bin/bash
set -e

mkdir -p ./bin/

# Collect all our files for processing
GOFILES=($(find . -type f -not -path "./nginx/*" -name '*.go' | grep -v client | grep -v vendor))

# Set OS_NAME if it's empty (local dev)
OS_NAME=$TRAVIS_OS_NAME
if [[ "$OS_NAME" == "" ]]; then
    if [[ $(uname -s) == "Darwin" ]]; then
        export OS_NAME=osx
    else
        export OS_NAME=linux
    fi
fi
echo "running go linters for $OS_NAME"

# Check gofmt
if [[ "$OS_NAME" != "windows" ]]; then
    set +e
    code=0
    for file in "${GOFILES[@]}"
    do
        # Go 1.17 introduced a migration with build constraints
        # and they offer a migration with gofmt
        # See https://go.googlesource.com/proposal/+/master/design/draft-gobuild.md#transition for more details
        if [[ "$file" == "./pkged.go" ]];
        then
            gofmt -s -w pkged.go
        fi

        # Check the file's formatting
        test -z $(gofmt -s -l $file)
        if [[ $? != 0 ]];
        then
            code=1
            echo "$file is not formatted"
        fi
    done
    set -e
    if [[ $code != 0 ]];
    then
        exit $code
    fi

    echo "finished gofmt check"
fi

# Would be set to 'moov-io' or 'moovfinancial'
org=$(go mod why | head -n1  | awk -F'/' '{print $2}')

# Reject moovfinancial dependencies in moov-io projects
if [[ "$org" == "moov-io" ]];
then
    # Fail our build if we find moovfinancial dependencies
    if go list -m all | grep moovfinancial;
    then
        echo "Found github.com/moovfinancial dependencies in OSS. Please remove"
        exit 1
    fi
fi

# Verify we're using the latest version of github.com/moovfinancial/events if it's a dependency
if [[ "$org" == "moovfinancial" ]];
then
  eventsLibrary="github.com/moovfinancial/events"
  eventsVersion=$( go list -f '{{if not .Indirect}}{{.}}{{end}}' -u -m -mod=mod $eventsLibrary | awk -F'[][]' '{print $2}')
  if [[ $eventsVersion ]]
  then
      echo "$eventsLibrary needs to be updated to the latest release: $eventsVersion"
      echo "Run 'go get -u ""$eventsLibrary""@latest' to resolve this issue"
      exit 1
  fi
fi

# gitleaks
# Right now there are some false positives which make it harder to scan
# See: https://github.com/zricethezav/gitleaks/issues/394
if [[ "$EXPERIMENTAL" == *"gitleaks"* ]]; then
    if [[ "$OS_NAME" == "linux" ]]; then wget -q -O ./bin/gitleaks https://github.com/zricethezav/gitleaks/releases/download/v7.6.1/gitleaks-linux-amd64; fi
    if [[ "$OS_NAME" == "osx" ]]; then wget -q -O ./bin/gitleaks https://github.com/zricethezav/gitleaks/releases/download/v7.6.1/gitleaks-darwin-amd64; fi

    if [[ "$OS_NAME" != "windows" ]]; then
        chmod +x ./bin/gitleaks

        echo "gitleaks version: "$(./bin/gitleaks --version)

        # Scan a few of the most recent commits
        depth=10
        if [ -n "$GITLEAKS_DEPTH" ]; then
            depth=$GITLEAKS_DEPTH
        fi
        ./bin/gitleaks --depth=$depth --path=$(pwd) --verbose
    fi

    echo "finished gitleaks check"
fi

# nancy (vulnerable dependencies)
if [[ "$OS_NAME" == "linux" ]]; then wget -q -O ./bin/nancy https://github.com/sonatype-nexus-community/nancy/releases/download/v1.0.29/nancy-v1.0.29-linux-amd64; fi
if [[ "$OS_NAME" == "osx" ]]; then wget -q -O ./bin/nancy https://github.com/sonatype-nexus-community/nancy/releases/download/v1.0.29/nancy-v1.0.29-darwin-amd64; fi
if [[ "$OS_NAME" != "windows" ]]; then
    chmod +x ./bin/nancy
    ./bin/nancy --version

    ignored_deps=(
        # Consul Enterprise
        CVE-2018-19653
        CVE-2020-13250
        CVE-2020-7219
        # Vault Enterprise
        CVE-2020-10660
        CVE-2020-10661
        CVE-2020-13223
        CVE-2020-7220
        # etcd
        CVE-2020-15114
        CVE-2020-15115
        CVE-2020-15136
        # jwt-go
        CVE-2020-26160
    )
    ignored=$(printf ",%s" "${ignored_deps[@]}")
    ignored=${ignored:1}

    # Append additional CVEs
    if [ -n "$IGNORED_CVES" ];
    then
        ignored="$ignored"",""$IGNORED_CVES"
    fi

    # Clean nancy cache
    ./bin/nancy --clean-cache

    # Ignore Consul and Vault Enterprise, they need a gocloud.dev release
    go list -mod=mod -m all | ./bin/nancy --skip-update-check --loud sleuth --exclude-vulnerability "$ignored"

    echo "" # newline
    echo "finished nancy check"
fi

# golangci-lint
if [[ "$OS_NAME" != "windows" ]]; then
    wget -q -O - -q https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s v1.43.0

    enabled="-E=asciicheck,bidichk,bodyclose,exhaustive,gocyclo,misspell,rowserrcheck"
    if [ -n "$GOLANGCI_LINTERS" ];
    then
        enabled="$enabled"",$GOLANGCI_LINTERS"
    fi

    ./bin/golangci-lint --version
    ./bin/golangci-lint $GOLANGCI_FLAGS run "$enabled" --verbose --skip-dirs="(admin|client)" --timeout=5m --disable=errcheck

    echo "finished golangci-lint check"
fi

## Clear GOARCH and GOOS for testing...
GOARCH=''
GOOS=''
GORACE='-race'
if [[ "$CGO_ENABLED" == "0" ]];
then
    GORACE=''
fi

# Run 'go test'
if [[ "$OS_NAME" == "windows" ]]; then
    # Just run short tests on Windows as we don't have Docker support in tests worked out for the database tests
    go test ./... "$GORACE" -short -coverprofile=coverage.txt -covermode=atomic
fi
if [[ "$OS_NAME" != "windows" ]]; then
    if [[ "$COVER_THRESHOLD" == "disabled" ]]; then
        go test ./... "$GORACE" -count 1
    else
        go test ./... "$GORACE" -coverprofile=coverage.txt -covermode=atomic -count 1
    fi
fi

# Verify Code Coverage Threshold
if [[ "$COVER_THRESHOLD" != "" ]]; then
    totalCoverage=$(go tool cover -func=coverage.txt | grep total | grep -Eo '[0-9]+\.[0-9]+')
    echo "Project has $totalCoverage% statement coverage."

    if [[ "$totalCoverage" < "$COVER_THRESHOLD" ]]; then
        echo "ERROR: statement coverage is not sufficient, $COVER_THRESHOLD% is required"
        exit 1
    else
        echo "SUCCESS: project has sufficient statement coverage"
    fi
else
    echo "Skipping code coverage threshold, consider setting COVER_THRESHOLD. (Example: 85.0)"
fi

echo "finished running Go tests"
