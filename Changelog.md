# Changelog

## [0.26.0](https://github.com/windowkit/appkit/compare/v0.25.0...v0.26.0) (2026-10-04)


### Features

* createLayout's `justify` sets lines to fill the width at their word separators after the typesetter breaks them, so a kept typesetter is justified again at another width without shaping anything ([#115](https://github.com/windowkit/appkit/issues/115)) ([6116d06](https://github.com/windowkit/appkit/commit/6116d06bc983e9f50c9f4fea2d6164fa0e4d8080))

## [0.25.0](https://github.com/windowkit/appkit/compare/v0.24.0...v0.25.0) (2026-10-04)


### Features

* setLayerProps' contentsGravity, how a layer's contents sit in bounds not their size, named as they look, so a renderer can anchor a pane's last frame while it grows where Core Animation stretched it ([#113](https://github.com/windowkit/appkit/issues/113)) ([8a1c02a](https://github.com/windowkit/appkit/commit/8a1c02a6525be6a0fa0de1a33b9e50f33642908d))

## [0.24.0](https://github.com/windowkit/appkit/compare/v0.23.0...v0.24.0) (2026-10-03)


### Features

* ctxClip takes the fill rule ctxFill takes, so a ring clipped evenodd cuts a ring where it cut the square around it ([#111](https://github.com/windowkit/appkit/issues/111)) ([a8f5248](https://github.com/windowkit/appkit/commit/a8f524815659938f99fd2738199dcc121faf5595))

## [0.23.0](https://github.com/windowkit/appkit/compare/v0.22.0...v0.23.0) (2026-10-03)


### Features

* ctxSetImageSmoothing, how an image drawn scaled or turned is resampled, so a surface drawn a tile at a time through a perspective costs each tile its own pixels where it cost the whole surface: 784 tiles of a 1400x1120 surface in 27ms where they took 200 ([#109](https://github.com/windowkit/appkit/issues/109)) ([3d6b898](https://github.com/windowkit/appkit/commit/3d6b89878cddea8e3186bc661fab0bcfe575c63c))

## [0.22.0](https://github.com/windowkit/appkit/compare/v0.21.0...v0.22.0) (2026-10-02)


### Features

* createPlayer, a file or URL played by AVFoundation on an AVPlayerLayer a renderer places among its own layers, with the frame showing copied into a surface in the same colours and its state as events, re-landed on main, where [#104](https://github.com/windowkit/appkit/issues/104) merged into [#103](https://github.com/windowkit/appkit/issues/103)'s branch after [#103](https://github.com/windowkit/appkit/issues/103) had merged and 0.21.0 shipped without it ([#107](https://github.com/windowkit/appkit/issues/107)) ([76e520e](https://github.com/windowkit/appkit/commit/76e520e0e3375c2e21856b786d61ee4a8809ef34))

## [0.21.0](https://github.com/windowkit/appkit/compare/v0.20.0...v0.21.0) (2026-10-02)


### Features

* a font made at a display's scale, so text on a Retina display is set as AppKit sets it, where a font made at its device pixel size read San Francisco's optical size and tracking and Apple Color Emoji's at twice the point size ([#106](https://github.com/windowkit/appkit/issues/106)) ([ca80cf0](https://github.com/windowkit/appkit/commit/ca80cf0d657d61c3e4d576e7e18811b60a94bc3c))
* video surfaces, a YCbCr or BGRA IOSurface a layer shows as it is with the frame written in, and the same frame converted into a 2D surface in the colours the layer shows it in ([#103](https://github.com/windowkit/appkit/issues/103)) ([6974ed8](https://github.com/windowkit/appkit/commit/6974ed892416cd63f328fbaf5b4ba9534a47c60e))

## [0.20.0](https://github.com/windowkit/appkit/compare/v0.19.0...v0.20.0) (2026-10-02)


### Features

* popUpMenu, a control's menu dropped from a frame in a window as an NSPopUpButton's drops, the current item over the control and checked, answering the id chosen or null, where a renderer had only menus it drew to look like one ([#101](https://github.com/windowkit/appkit/issues/101)) ([e0b4e7f](https://github.com/windowkit/appkit/commit/e0b4e7f0cfd6204f9990e54549db370ede5a0586))

## [0.19.0](https://github.com/windowkit/appkit/compare/v0.18.0...v0.19.0) (2026-10-02)


### Features

* a layer transform is a matrix, CSS's matrix() and matrix3d() on setLayerProps and as animation values, transformForms() says so, and a negative animation delay starts it that far in ([#97](https://github.com/windowkit/appkit/issues/97)) ([985ca2b](https://github.com/windowkit/appkit/commit/985ca2b0045c0c0a862a24fbeb4fc0717622bf00))


### Bug Fixes

* the IOSurfaces the bridge presents name sRGB as their colour space, so a window's bitmap is colour-managed as its layers are, where on a wide-gamut display it went to the panel as the panel's own numbers ([#99](https://github.com/windowkit/appkit/issues/99)) ([5351f7b](https://github.com/windowkit/appkit/commit/5351f7bfb56790228add5f68e54e27254a1322c8))

## [0.18.0](https://github.com/windowkit/appkit/compare/v0.17.0...v0.18.0) (2026-10-02)


### Features

* ctxDrawSurfaceFaded, a surface drawn under an alpha from its pixels scaled, at a fifth of what CoreGraphics' own alpha costs ([#94](https://github.com/windowkit/appkit/issues/94)) ([0b3f0ce](https://github.com/windowkit/appkit/commit/0b3f0ce3d2f3dc593f6acb2d280d5d09b1bf2135))


### Bug Fixes

* fontFromData reads a face and no longer registers it with CoreText ([#93](https://github.com/windowkit/appkit/issues/93)) ([41c64ff](https://github.com/windowkit/appkit/commit/41c64ff9d1e928e59f7590c6a6ea8785211ff6cf)), closes [#92](https://github.com/windowkit/appkit/issues/92)
* the notification event function is the main thread's environment's, made once — a worker that loads the module first no longer swallows every response ([#96](https://github.com/windowkit/appkit/issues/96)) ([9c5010f](https://github.com/windowkit/appkit/commit/9c5010f2dfb70bbf9c4440fad2a6a22e8abd39ae))

## [0.17.0](https://github.com/windowkit/appkit/compare/v0.16.0...v0.17.0) (2026-09-29)


### Features

* ctxRoundRectXY, a rounded rect whose corners are elliptical ([#90](https://github.com/windowkit/appkit/issues/90)) ([0727e06](https://github.com/windowkit/appkit/commit/0727e064cc4a06b04380edc65ac17c4c67172ae3))

## [0.16.0](https://github.com/windowkit/appkit/compare/v0.15.2...v0.16.0) (2026-09-28)


### Features

* a push bezel as tall as its frame, for a title that wraps ([#88](https://github.com/windowkit/appkit/issues/88)) ([7c38b72](https://github.com/windowkit/appkit/commit/7c38b7252ea4809e6c2beab5015dcde0b1addf8c))

## [0.15.2](https://github.com/windowkit/appkit/compare/v0.15.1...v0.15.2) (2026-09-27)


### Bug Fixes

* a word no part of which fits its line runs on whole ([#86](https://github.com/windowkit/appkit/issues/86)) ([88a2119](https://github.com/windowkit/appkit/commit/88a21191ab5b88513ed72b08c6cf82d830633572))

## [0.15.1](https://github.com/windowkit/appkit/compare/v0.15.0...v0.15.1) (2026-09-26)


### Bug Fixes

* a no-break space a line ends on keeps its room ([#84](https://github.com/windowkit/appkit/issues/84)) ([d3af9c5](https://github.com/windowkit/appkit/commit/d3af9c5ca7a63393389e80ea694fc19dc6036c32))

## [0.15.0](https://github.com/windowkit/appkit/compare/v0.14.1...v0.15.0) (2026-09-26)


### Bug Fixes

* a line's glyphs sit in the middle of its line box, as ntk sets them ([#80](https://github.com/windowkit/appkit/issues/80)) ([aac1c23](https://github.com/windowkit/appkit/commit/aac1c2355f094929a438f2949c262b392e7d374e))
* a line's width leaves out the white space it ends on, as ntk's does ([#81](https://github.com/windowkit/appkit/issues/81)) ([22313f4](https://github.com/windowkit/appkit/commit/22313f4420f5bf72ddf1f73e0e1b2cca7958fcc1))

## [0.14.1](https://github.com/windowkit/appkit/compare/v0.14.0...v0.14.1) (2026-09-26)


### Bug Fixes

* showWindow announces the window as shown, once it is published ([#77](https://github.com/windowkit/appkit/issues/77)) ([837d73e](https://github.com/windowkit/appkit/commit/837d73e60f0e156bd67cb0a56d78ff16b6ee1eb8))

## [0.14.0](https://github.com/windowkit/appkit/compare/v0.13.0...v0.14.0) (2026-09-25)


### Features

* a paragraph's typesetter, kept and laid out again at another width ([#75](https://github.com/windowkit/appkit/issues/75)) ([63cbc8d](https://github.com/windowkit/appkit/commit/63cbc8d6d4b9db36e8b7a5f3dbe50e1543b28edd))

## [0.13.0](https://github.com/windowkit/appkit/compare/v0.12.0...v0.13.0) (2026-09-24)


### Features

* layoutCoverage — a layout's coverage without a surface, the outlines' own ([#73](https://github.com/windowkit/appkit/issues/73)) ([9af7051](https://github.com/windowkit/appkit/commit/9af7051cd318b925423b2f34f77255827b94a3ae))

## [0.12.0](https://github.com/windowkit/appkit/compare/v0.11.0...v0.12.0) (2026-09-17)


### Features

* ctxDrawSymbol and symbolSize, SF Symbols drawn in a surface in the fill colour ([#71](https://github.com/windowkit/appkit/issues/71)) ([6ee673c](https://github.com/windowkit/appkit/commit/6ee673c4791f23912190b49ba3761fe8108983b4))

## [0.11.0](https://github.com/windowkit/appkit/compare/v0.10.0...v0.11.0) (2026-09-17)


### Features

* fontApplyFeatures, and letterSpacing on createLayout spans and fontShapeText ([#70](https://github.com/windowkit/appkit/issues/70)) ([d0a5811](https://github.com/windowkit/appkit/commit/d0a5811bc411a5991a19316de4ccfbc274cf3d93))


### Bug Fixes

* no threadsafe function touched once its environment has begun to end — an answer from another thread after a worker ends no longer aborts the process ([#68](https://github.com/windowkit/appkit/issues/68)) ([6906429](https://github.com/windowkit/appkit/commit/690642905679a0431936baf4d8bda7021ca3e36e))

## [0.10.0](https://github.com/windowkit/appkit/compare/v0.9.0...v0.10.0) (2026-09-11)


### Features

* control bezels from a worker — measureControl / drawControlIntoSurface made on the UI thread, answered through a callback ([#60](https://github.com/windowkit/appkit/issues/60)) ([0b17653](https://github.com/windowkit/appkit/commit/0b176533aa97f2211014ce2511d548cb4ffde838)), closes [#54](https://github.com/windowkit/appkit/issues/54)
* frames from a worker — a frame's layer changes as one batch applied on the UI thread, layer handles, IOSurface buffers handed back by event ([#58](https://github.com/windowkit/appkit/issues/58)) ([f86ad30](https://github.com/windowkit/appkit/commit/f86ad300f0e2f5a2f544e11f0f894a8ac56bd43b)), closes [#52](https://github.com/windowkit/appkit/issues/52)
* the activation policy before launch without the app's code — APPKIT_ACTIVATION_POLICY and runMain({ activationPolicy }); the policy published as it is decided ([#67](https://github.com/windowkit/appkit/issues/67)) ([8e41f93](https://github.com/windowkit/appkit/commit/8e41f93cfcc3cdd1483c976e76be45c7a7f9a57e)), closes [#64](https://github.com/windowkit/appkit/issues/64)
* the AppKit verbs from a worker — handles answered at the call, commands, published reads, callback answers ([#57](https://github.com/windowkit/appkit/issues/57)) ([68fc4a1](https://github.com/windowkit/appkit/commit/68fc4a1403c64a871421da2a9d63aee2db0d60af)), closes [#51](https://github.com/windowkit/appkit/issues/51)
* the live-resize handshake — a bounded wait for a frame at the new size, applied in the resize's own transaction ([#59](https://github.com/windowkit/appkit/issues/59)) ([1737764](https://github.com/windowkit/appkit/commit/17377646f69cf5af2dc3ef5501ceb604b571bfb0))
* threaded mode's core — the main thread in a real [NSApp run], commands in through the common modes, events out in batches, published state ([#55](https://github.com/windowkit/appkit/issues/55)) ([d005e55](https://github.com/windowkit/appkit/commit/d005e55ee4df4ba2b4c2dedec0bf9340439af208))
* window-live-resize begin / end, and liveResize in the published window state ([#66](https://github.com/windowkit/appkit/issues/66)) ([0dc3b69](https://github.com/windowkit/appkit/commit/0dc3b69131616939c86e9cbdd0c3673ebde61f19)), closes [#63](https://github.com/windowkit/appkit/issues/63)


### Bug Fixes

* an exception from connect's callback, or any callback the bridge answers through, is the environment's uncaught exception — no longer a dropped warning ([#65](https://github.com/windowkit/appkit/issues/65)) ([f22eb72](https://github.com/windowkit/appkit/commit/f22eb72bf5e1f97d0a0060a2f7a998471ae83e2a)), closes [#62](https://github.com/windowkit/appkit/issues/62)
* no answer into an environment that is ending, from any threadsafe function — the colour sampler, permissions, calendars, notifications ([#61](https://github.com/windowkit/appkit/issues/61)) ([45eb2dc](https://github.com/windowkit/appkit/commit/45eb2dcdf8e10b58e5e79f05dbc238ad841e107a))

## [0.9.0](https://github.com/windowkit/appkit/compare/v0.8.0...v0.9.0) (2026-09-10)


### Features

* one colour off the screen through NSColorSampler — the eyedropper's macOS rung, a cancel as an ordinary answer ([#47](https://github.com/windowkit/appkit/issues/47)) ([2a6a1d6](https://github.com/windowkit/appkit/commit/2a6a1d6e0398813f55ede70de936c0ead8125563))

## [0.8.0](https://github.com/windowkit/appkit/compare/v0.7.0...v0.8.0) (2026-09-08)


### Features

* creating, changing and removing events through EventKit — the span for a recurring one, the occurrence it reaches, the default calendar, a batch ([#45](https://github.com/windowkit/appkit/issues/45)) ([9469006](https://github.com/windowkit/appkit/commit/94690061b709bc536e1e1e6e4ec46fc22a3acdbe))
* privacy authorizations for calendars and reminders — EventKit's TCC grants, including macOS 14's write-only one ([#42](https://github.com/windowkit/appkit/issues/42)) ([c49685e](https://github.com/windowkit/appkit/commit/c49685e109eabafa9bf2f48877d61a4050cc3700)), closes [#39](https://github.com/windowkit/appkit/issues/39)
* the user's calendars and the occurrences in a range, through EventKit, with the store's change as a backend event ([#44](https://github.com/windowkit/appkit/issues/44)) ([a947e50](https://github.com/windowkit/appkit/commit/a947e50e7445e44b6aae96f1b63eb18c13132836))

## [0.7.0](https://github.com/windowkit/appkit/compare/v0.6.0...v0.7.0) (2026-09-07)


### Features

* globalCompositeOperation on a surface's context, and a memcpy blit for a surface composited at a translate ([#37](https://github.com/windowkit/appkit/issues/37)) ([c53c94d](https://github.com/windowkit/appkit/commit/c53c94d94230ddc739ebe639a656fba2c642a89a))

## [0.6.0](https://github.com/windowkit/appkit/compare/v0.5.1...v0.6.0) (2026-09-07)


### Features

* a window the pointer passes through — ignoresMouseEvents at creation and as a setter, and windowNumberAtPoint to see it ([#35](https://github.com/windowkit/appkit/issues/35)) ([b6193ea](https://github.com/windowkit/appkit/commit/b6193ea6b2560e3ebff8ff33b217461facf6c5af))

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
