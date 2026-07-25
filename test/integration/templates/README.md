# Production template fixtures

`qwen3.5-3.6-froggeric-v21.3.jinja` is an exact copy of the unified Qwen 3.5/3.6 community template from:

- Source: https://huggingface.co/froggeric/Qwen-Fixed-Chat-Templates
- Upstream commit: `23a40b0bd4d197c31d39e3c442fd2cd6100b3971`
- Upstream template version: `qwen3.6-froggeric-v21.3`
- SHA-256: `d203f3342d8a7f8474dd55563eece3a26e71b21c6f667c9db9c93b762b3bf997`
- License: Apache-2.0; see `qwen3.5-3.6-froggeric-v21.3.LICENSE.txt`

The fixture remains byte-identical so the integration suite verifies the community artifact users actually install. Its tests are adapted from upstream `scripts/test_v21.py` and exercise both Qwen 3.5 and Qwen 3.6 because upstream intentionally uses one template for all variants.
