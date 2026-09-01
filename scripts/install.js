// Install-time dispatch: use the bundled prebuilt binary when one matches
// this platform/arch and actually loads; otherwise compile with node-gyp.
// A Mac with no Xcode command-line tools therefore installs from the
// tarball alone. Force a source build with: npm install --build-from-source
'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

// darwin-only package (AppKit / Core Animation). On any other platform the
// package is inert; there is nothing to build, and `os` in package.json
// already warns npm — do not fail the install of a cross-platform consumer.
if (process.platform !== 'darwin') {
  console.log('@windowkit/appkit: not macOS — skipping native build');
  process.exit(0);
}

const root = path.join(__dirname, '..');
const target = `${process.platform}-${process.arch}`;
const prebuilt = path.join(root, 'prebuilds', target, 'calayers.node');

if (
  process.env.npm_config_build_from_source !== 'true' &&
  fs.existsSync(prebuilt)
) {
  try {
    require(prebuilt); // loading registers exports and touches nothing else
    console.log(`@windowkit/appkit: using bundled prebuilt binary (${target})`);
    process.exit(0);
  } catch (e) {
    console.warn(
      `@windowkit/appkit: bundled prebuild did not load (${e.message}); compiling instead`,
    );
  }
}

// npm points npm_config_node_gyp at its own copy; fall back to PATH
const gyp = process.env.npm_config_node_gyp;
const result = gyp
  ? spawnSync(process.execPath, [gyp, 'rebuild'], { cwd: root, stdio: 'inherit' })
  : spawnSync('node-gyp', ['rebuild'], { cwd: root, stdio: 'inherit' });
if (result.error) {
  console.error(
    `@windowkit/appkit: could not run node-gyp (${result.error.message})`,
  );
  console.error(
    '@windowkit/appkit: no prebuilt binary matches this system and no ' +
      'toolchain is available. Install the Xcode command-line tools ' +
      '(xcode-select --install) and reinstall.',
  );
  process.exit(1);
}
process.exit(result.status === null ? 1 : result.status);
