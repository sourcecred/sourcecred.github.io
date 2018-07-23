#!/bin/sh
set -eu

: "${SOURCECRED_REMOTE:=https://github.com/sourcecred/sourcecred.git}"
: "${SOURCECRED_REF:=origin/master}"

: "${SOURCE_BRANCH:=source}"
: "${DEPLOY_BRANCH:=master}"
: "${REMOTE:=origin}"

export GIT_CONFIG_NOSYSTEM=1
export GIT_ATTR_NOSYSTEM=1

main() {
    parse_args "$@"

    toplevel="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
    cd "${toplevel}"

    sourcecred_repo=
    preview_dir=
    trap cleanup EXIT

    ensure_clean_working_tree
    build_and_deploy
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -n|--dry-run)
                printf 'Setting DRY_RUN=1.\n'
                DRY_RUN=1
                ;;
            *)
                printf >&2 'unknown argument: %s\n' "$1"
                exit 1
                ;;
        esac
        shift
    done
}

# Adapted from:
# https://github.com/git/git/blob/8d530c4d64ffcc853889f7b385f554d53db375ed/git-sh-setup.sh#L207-L222
ensure_clean_working_tree() {
    err=0
    if ! git diff-files --quiet --ignore-submodules; then
        printf >&2 'Cannot deploy: You have unstaged changes.\n'
        err=1
    fi
    if ! git diff-index --cached --quiet --ignore-submodules HEAD -- ; then
        if [ "${err}" -eq 0 ]; then
            printf >&2 'Cannot deploy: Your index contains uncommitted changes.\n'
        else
            printf >&2 'Additionally, your index contains uncommitted changes.\n'
        fi
        err=1
    fi
    if [ "${err}" -ne 0 ]; then
        exit "${err}"
    fi
}

build_and_deploy() {
    sourcecred_data="$(mktemp -d --suffix ".sourcecred-data")"
    export SOURCECRED_DIRECTORY="${sourcecred_data}"

    sourcecred_repo="$(mktemp -d --suffix ".sourcecred-repo")"
    git clone "${SOURCECRED_REMOTE}" "${sourcecred_repo}"
    sourcecred_hash="$(
        git -C "${sourcecred_repo}" rev-parse --verify "${SOURCECRED_REF}" --
    )"
    git -C "${sourcecred_repo}" checkout --detach "${sourcecred_hash}"
    (
        cd "${sourcecred_repo}"
        yarn
        yarn backend
        yarn build
        node ./bin/sourcecred.js load sourcecred example-github
        node ./bin/sourcecred.js load sourcecred example-git
    )

    git fetch -q "${REMOTE}"
    if ! base_commit="$(
            git rev-parse --verify "refs/remotes/${REMOTE}/${DEPLOY_BRANCH}" --
    )"; then
        printf >&2 'No deploy branch %s on remote %s.\n' \
            "${DEPLOY_BRANCH}" "${REMOTE}"
        exit 1
    fi
    git checkout --detach "${base_commit}"
    rm ./.git/index
    git clean -qfdx
    # Explode the `build/` directory into the current directory.
    find "${sourcecred_repo}/build/" -mindepth 1 -maxdepth 1 \
        \( -name .git -prune \) -o \
        -exec cp -r -t . -- {} +
    # Copy the SourceCred data into the appropriate API route.
    mkdir ./api/
    mkdir ./api/v1/
    cp -r "${sourcecred_data}" ./api/v1/data
    git add --all .
    git commit -m "deploy-v1: ${sourcecred_hash}"
    deploy_commit="$(git rev-parse HEAD)"

    preview_dir="$(mktemp -d --suffix ".sourcecred-prvw")"
    git clone -q --no-local --no-checkout . "${preview_dir}"
    git -C "${preview_dir}" checkout -q --detach "${deploy_commit}"

    printf '\n'
    printf 'Please review the build output now---run:\n'
    printf '    cd "%s" && python -m SimpleHTTPServer\n' "${preview_dir}"
    printf 'Do you want to deploy? yes/no> '
    read -r line
    if [ "${line}" = yes ]; then
        (
            set -x;
            git push ${DRY_RUN:+--dry-run} \
                "${REMOTE}" \
                "${deploy_commit}:${DEPLOY_BRANCH}" \
                ;
        )
    else
        printf 'Aborting.\n'
    fi

    git checkout "${SOURCE_BRANCH}"
    printf 'Done.\n'
}

cleanup() {
    if [ -d "${sourcecred_repo}" ]; then
        rm -rf "${sourcecred_repo}"
    fi
    if [ -d "${preview_dir}" ]; then
        rm -rf "${preview_dir}"
    fi
}

main "$@"
