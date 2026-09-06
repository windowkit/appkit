# Changelog

## [0.5.1](https://github.com/windowkit/appkit/compare/v0.5.0...v0.5.1) (2026-09-06)


### Bug Fixes

* every colour crossing the bridge is sRGB, and colorSpace() says so ([#33](https://github.com/windowkit/appkit/issues/33)) ([7f005ad](https://github.com/windowkit/appkit/commit/7f005adbe8b95f2015088e31e371093e89ed2f8d))

## [0.5.0](https://github.com/windowkit/appkit/compare/v0.4.0...v0.5.0) (2026-09-06)


### Features

* accessibility display options — reduce motion and its siblings, the change as a backend event ([#32](https://github.com/windowkit/appkit/issues/32)) ([2835d12](https://github.com/windowkit/appkit/commit/2835d1214f46db503b6fdd1f05a2ae9686cf20a7))
* animation verbs — control-point timing, additive, delay, keyframes, springs, presentationValue, completion events ([#30](https://github.com/windowkit/appkit/issues/30)) ([e9eac8e](https://github.com/windowkit/appkit/commit/e9eac8e4c2096811fe094184ae8bdc698be34b97))
* app lifecycle — open-URL/open-file, reopen and quit requests through the app delegate ([d5e7d77](https://github.com/windowkit/appkit/commit/d5e7d772ab293119f2e09febb10f87c5bf3b1ff1))
* app lifecycle events — open-URL/open-file, reopen and quit requests through the app delegate ([a0580e0](https://github.com/windowkit/appkit/commit/a0580e0d4b92515e6bdc7f0b7329a13c1604081f)), closes [#18](https://github.com/windowkit/appkit/issues/18)
* desktop notifications — UNUserNotificationCenter settings, authorization, categories, post/update/remove, action events ([c5da10e](https://github.com/windowkit/appkit/commit/c5da10e521ce372ad06223a95ab6457b81f87bb4))
* desktop notifications — UNUserNotificationCenter: settings, authorization, categories, post/update/remove, action events ([646105a](https://github.com/windowkit/appkit/commit/646105a261a298b8c9e162dbdbdccd4c6ec0bb41))
* Dock and app-switcher presence — badge, user attention, Dock menu, activation policy, app name ([547b9b4](https://github.com/windowkit/appkit/commit/547b9b4726ce3df8b9aa054b97fd308559cc8170))
* Dock and app-switcher presence — badge, user attention, Dock menu, activation policy, app name ([41ab634](https://github.com/windowkit/appkit/commit/41ab6348056326aa259e84211bfbfb12c3752390))
* drag and drop — NSDraggingDestination on the hosting view, NSDraggingSource from it ([8aa305a](https://github.com/windowkit/appkit/commit/8aa305aa58a2af24ef6340bbfb987a812af5e4b8))
* drag and drop — NSDraggingDestination on the hosting view, NSDraggingSource from it ([90cf29a](https://github.com/windowkit/appkit/commit/90cf29afb7ccd87fb29a3b9dc7e1f72fa6d508a9)), closes [#16](https://github.com/windowkit/appkit/issues/16)
* native file open/save panels (NSOpenPanel / NSSavePanel) ([51c38c2](https://github.com/windowkit/appkit/commit/51c38c28a81ca54011c3f20b7d163a97b75f4ce5))
* native file open/save panels (NSOpenPanel / NSSavePanel) ([8b1a198](https://github.com/windowkit/appkit/commit/8b1a1988ba69cb22d6377e2d6f021590a423a26d)), closes [#14](https://github.com/windowkit/appkit/issues/14)
* NSStatusItem, the menu-bar extra — image/title/tooltip, the main menu's item spec, clicks as events ([8e68294](https://github.com/windowkit/appkit/commit/8e68294986663a5bb53ccc3470c542e739b765f0))
* NSStatusItem, the menu-bar extra — image/title/tooltip, the main menu's item spec, clicks as events ([2da777e](https://github.com/windowkit/appkit/commit/2da777eca659b8c32bf8506ff7607f35414ee14c))
* privacy (TCC) authorizations — authorizationStatus, requestAuthorization, openPrivacySettings ([265e638](https://github.com/windowkit/appkit/commit/265e638b87bcdab50046cf04e809532bbfd8c3c7))
* privacy (TCC) authorizations — status, request, openPrivacySettings ([5cbbc57](https://github.com/windowkit/appkit/commit/5cbbc5739a57511400c9401c33418c0f912b8bcd))


### Bug Fixes

* never show a tab bar; getWindowFrame reports the content view's rect ([63742ec](https://github.com/windowkit/appkit/commit/63742ec7076649d0de780ff92b2896220f1097ba))
* never show a tab bar; report the content view's rect from getWindowFrame and geometry events ([9eaa8a5](https://github.com/windowkit/appkit/commit/9eaa8a584985fdaf859b7b3f493a02f26f3719f4)), closes [#12](https://github.com/windowkit/appkit/issues/12)
* static event-callback references outlive the env — suppress their destructors ([bb8d2d9](https://github.com/windowkit/appkit/commit/bb8d2d9a67cf5a8d828f4978484931d2ee4ae394))

## [0.4.0](https://github.com/windowkit/appkit/compare/v0.3.0...v0.4.0) (2026-09-03)


### Features

* surface memory accounting and releaseSurface, listScreens fps, window-occlusion events ([a64c672](https://github.com/windowkit/appkit/commit/a64c672aaa24e58dc4db1be5e20aa90b2db166b9))
* surfaces account their bytes to V8 and take releaseSurface; listScreens reports fps; window-occlusion events ([64d899f](https://github.com/windowkit/appkit/commit/64d899f8756cab2d73f68dca66bc697863f9af70))

## [0.3.0](https://github.com/windowkit/appkit/compare/v0.2.0...v0.3.0) (2026-09-02)


### Features

* fontShapeText and fontWithSize: a shaped line read back as glyph runs, and a face at another size ([84ea297](https://github.com/windowkit/appkit/commit/84ea297b6fc6213896a3b2f5bfef500ced40b7b0))
* fontShapeText and fontWithSize: a shaped line read back as glyph runs, and a face at another size ([bab51ae](https://github.com/windowkit/appkit/commit/bab51aed1a604d2dc9838b9f9d8b6e572f448958))

## [0.2.0](https://github.com/windowkit/appkit/compare/v0.1.0...v0.2.0) (2026-09-02)


### Features

* backend surface for react-x11 (windows, events, surfaces, text) ([111c20b](https://github.com/windowkit/appkit/commit/111c20bbd0a4eeac95949f748b3e84802eb5251a))
* font catalogue, lineHeight as multiplier ([f96a61c](https://github.com/windowkit/appkit/commit/f96a61cf8d473712d9710c5513a27969b9b382a0))
* font handles, gradient text, shadows, transforms, shadow control ([45136ab](https://github.com/windowkit/appkit/commit/45136abb341a5e9cd1943221be3e50a86efb1875))
* glyph-level text natives — ids, advances, fallback face, ctxDrawGlyphs ([b9f47a6](https://github.com/windowkit/appkit/commit/b9f47a67b59002eb814f655eb64d20622ded40a8))
* glyph-level text natives — ids, advances, fallback face, ctxDrawGlyphs ([53b6838](https://github.com/windowkit/appkit/commit/53b6838dd17f8598cfbdb9da19cac56ea9a3b75d)), closes [#1](https://github.com/windowkit/appkit/issues/1)
* IOSurface layer contents — the GL presentation seam ([d20b6dc](https://github.com/windowkit/appkit/commit/d20b6dc04bfc339c420b8fa53a03d2dd9328c003))
* IOSurface-backed surfaces, lock/unlock, region copy ([934001e](https://github.com/windowkit/appkit/commit/934001ed9212e6f2705ebced6153973dac617e49))
* measure and render control bezels into surfaces ([b4df8cb](https://github.com/windowkit/appkit/commit/b4df8cbe483ab0688337c412e40a31f85de1cadf))
* menu item icons — SF Symbol names, PNG bytes ([56bdd63](https://github.com/windowkit/appkit/commit/56bdd63f7b003b7f24a5bc5aeb4c06dd7d0099c8))
* rect-confined scrollSurface, bounds origin in layer props ([460e28b](https://github.com/windowkit/appkit/commit/460e28b0316f704732a5e91ed5eb7c72c015b8d3))
* shared IOSurfaces for cross-process pane presentation ([82f755c](https://github.com/windowkit/appkit/commit/82f755cf3c75692e9f35b2604c0dc734efebd442))
* the macOS main menu, spec in, activations out ([c8092ac](https://github.com/windowkit/appkit/commit/c8092ac792503d74fb925d8fb4b5398d2971c9de))


### Bug Fixes

* canvas arc sweeps the canvas way ([d87adcd](https://github.com/windowkit/appkit/commit/d87adcd51fd64550d8536013201c13f923215349))
* caret line index and trailing-newline hit tests ([5d0d680](https://github.com/windowkit/appkit/commit/5d0d680875aa19171647cee33d7d9680fcce233c))
