#!/usr/bin/env bash
# Classify the result of `xcrun altool --upload-app`.
#
# Sourced by the publish steps of distribute-beta.yml and distribute-release.yml
# so both paths share one definition of "did this upload actually land?" — the
# logic used to be duplicated inline in each, and drifted into the same bug twice.
#
#   classify_upload <altool-exit-code> <altool-output>  →  one of:
#     accepted         ASC took the binary
#     already-present  the identical version+build is already there; safe to skip
#     failed           anything else; the caller must fail the job
classify_upload() {
  local rc="$1" out="$2"

  if [ "$rc" -eq 0 ] || grep -qE "UPLOAD SUCCEEDED|No errors uploading" <<<"$out"; then
    echo accepted; return
  fi

  # Benign ONLY for a true redundant upload — same version AND same build already
  # on ASC, which Apple reports as ITMS-90189 / "Redundant Binary Upload".
  #
  # Deliberately does NOT match the looser "already been used". Apple phrases the
  # -19232 build-number collision as "an attribute with a value that has already
  # been used", and that is a real failure needing a higher CFBundleVersion. The
  # wider pattern swallowed it as an idempotent re-run and reported the job green,
  # so failed uploads looked like successful ones.
  if grep -qiE "ITMS-90189|redundant binary upload" <<<"$out"; then
    echo already-present; return
  fi

  echo failed
}
