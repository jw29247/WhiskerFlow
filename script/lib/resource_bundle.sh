# Sourced by the packaging tests.
#
# SwiftPM names a target's resource bundle `<Package>_<Target>.bundle`, but its
# layout depends on the toolchain: older ones (CI) write the resources flat in
# the bundle, the Swift Build backend writes a real bundle with them under
# `Contents/Resources`. Prints the path of resource NAME inside BUNDLE in
# whichever layout it has, or fails if it is in neither.
resource_bundle_file() {
  local bundle="$1" name="$2"
  if [[ -f "$bundle/Contents/Resources/$name" ]]; then
    printf '%s\n' "$bundle/Contents/Resources/$name"
  elif [[ -f "$bundle/$name" ]]; then
    printf '%s\n' "$bundle/$name"
  else
    echo "FAIL: $name is in neither layout of $bundle" >&2
    return 1
  fi
}
