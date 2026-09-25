# Changelog

## 0.1.0 (2026-09-25)


### Features

* add adaptive test selection and optimize mutation runs ([#10](https://github.com/P4suta/gleam-mutants/issues/10)) ([353fa0d](https://github.com/P4suta/gleam-mutants/commit/353fa0deb9e10b8a76253e85aebb543e4db019ff))
* add Smartest adaptive verification ([#9](https://github.com/P4suta/gleam-mutants/issues/9)) ([3702ffd](https://github.com/P4suta/gleam-mutants/commit/3702ffd4b8a4b1c4fef69f386619c9d8a6a18718))
* drop either half of a concatenation ([#32](https://github.com/P4suta/gleam-mutants/issues/32)) ([a7000ef](https://github.com/P4suta/gleam-mutants/commit/a7000efba26fbb0bdf18afe7f5c6c1425ee71292))
* generate a function-typed argument instead of giving up ([#23](https://github.com/P4suta/gleam-mutants/issues/23)) ([742e877](https://github.com/P4suta/gleam-mutants/commit/742e8779d3891c4ad95773feb8015719fb77b090))
* harden list validation and ecosystem gates ([#5](https://github.com/P4suta/gleam-mutants/issues/5)) ([980a1c8](https://github.com/P4suta/gleam-mutants/commit/980a1c80c27ea4bec9c899bd1f91fae243088696))
* mutate an Option that is constructed ([#30](https://github.com/P4suta/gleam-mutants/issues/30)) ([c2da695](https://github.com/P4suta/gleam-mutants/commit/c2da695f7ae317ae9beac5c61ff251be31b2e78b))
* prepare gleam_mutants 1.0 release candidate ([#1](https://github.com/P4suta/gleam-mutants/issues/1)) ([c2659ef](https://github.com/P4suta/gleam-mutants/commit/c2659efdc647602bab2fa2a164719fa48edf194a))
* say why a mutant survived without being run ([#40](https://github.com/P4suta/gleam-mutants/issues/40)) ([2bfdd56](https://github.com/P4suta/gleam-mutants/commit/2bfdd569d232c44ba43bc0ce1a18e4536041b550))
* say why every mutant ran the whole suite ([#44](https://github.com/P4suta/gleam-mutants/issues/44)) ([31ac993](https://github.com/P4suta/gleam-mutants/commit/31ac9936ccf28ab8fc62add7a3abecf78766792e))
* settle a mutant that never answers differently ([#38](https://github.com/P4suta/gleam-mutants/issues/38)) ([df0e01c](https://github.com/P4suta/gleam-mutants/commit/df0e01c6770326e7a6b4d721ba3b92db382f7958))
* suggest tests that kill surviving mutants by differential execution ([#6](https://github.com/P4suta/gleam-mutants/issues/6)) ([8f3c9ed](https://github.com/P4suta/gleam-mutants/commit/8f3c9ed2d75b7939a2b660d363c837f5fa9e966a))
* take the sign off a negated integer ([#33](https://github.com/P4suta/gleam-mutants/issues/33)) ([216dfbf](https://github.com/P4suta/gleam-mutants/commit/216dfbf324cdef7995a47553106e6fd42716aee8))


### Bug Fixes

* apply into the nested test module a project already has ([#20](https://github.com/P4suta/gleam-mutants/issues/20)) ([529405e](https://github.com/P4suta/gleam-mutants/commit/529405e5cc463d1b89d6481e7533472d9d4cb288))
* compare every form Gleam allows, not the ones first written down ([#39](https://github.com/P4suta/gleam-mutants/issues/39)) ([47b8661](https://github.com/P4suta/gleam-mutants/commit/47b8661ab9c499993f3d80ad680cebf618fc4c63))
* name protocol files relative to the workspace ([#19](https://github.com/P4suta/gleam-mutants/issues/19)) ([a05077f](https://github.com/P4suta/gleam-mutants/commit/a05077f4feb7e0ec5621c677a75bb25521c5cf80))
* never leave an agreement standing where a parting was lost ([#42](https://github.com/P4suta/gleam-mutants/issues/42)) ([76921ea](https://github.com/P4suta/gleam-mutants/commit/76921ea41da6a7c40c80eeb99b4099cb03fb940f))
* probe a free type variable instead of giving up on it ([#21](https://github.com/P4suta/gleam-mutants/issues/21)) ([0bc6467](https://github.com/P4suta/gleam-mutants/commit/0bc64677182f32697c64ca19a5b2ce80f81b87dc))
* retry a packaging smoke past a Hex refusal ([#35](https://github.com/P4suta/gleam-mutants/issues/35)) ([f4f30af](https://github.com/P4suta/gleam-mutants/commit/f4f30af13098dd56165e0d0b280b2916fc122a60))
* say what the compile lane found out about a module constant ([#24](https://github.com/P4suta/gleam-mutants/issues/24)) ([fa543c8](https://github.com/P4suta/gleam-mutants/commit/fa543c83cb16f5811e51d522cf6b8a6691c5c229))
* spell the Option replacement the way the module can write it ([#31](https://github.com/P4suta/gleam-mutants/issues/31)) ([4d44bf6](https://github.com/P4suta/gleam-mutants/commit/4d44bf6feeef1acbbb210a9aa3502e6079a3dcaf))


### Performance Improvements

* hand a worker the build directory instead of making it build ([#36](https://github.com/P4suta/gleam-mutants/issues/36)) ([86af191](https://github.com/P4suta/gleam-mutants/commit/86af191690e5a6c4765173b95503e636502ac98c))
* keep a run's copy of the workspace between runs ([#37](https://github.com/P4suta/gleam-mutants/issues/37)) ([a39c4bf](https://github.com/P4suta/gleam-mutants/commit/a39c4bf05e77f558974ce2801a9eeb776b99a88f))

<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

## Changelog

<!-- Release entries below are maintained by release-please. -->
