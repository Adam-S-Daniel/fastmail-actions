# Convenience targets. Uses '>' as the recipe prefix (GNU Make 3.82+) so no
# hard tabs are required. On Windows, prefer ./test-local.ps1 directly.
.RECIPEPREFIX = >
.PHONY: test act act-add-from act-discover act-tests

# Fast: Pester in mock mode (no Docker, no token).
test:
> pwsh -NoProfile -File ./test-local.ps1

# Run every workflow through act (Docker required).
act:
> pwsh -NoProfile -File ./test-local.ps1 -Act

act-add-from:
> pwsh -NoProfile -File ./test-local.ps1 -Act -Job add-from-address

act-discover:
> pwsh -NoProfile -File ./test-local.ps1 -Act -Job add-received-from-addresses

act-tests:
> pwsh -NoProfile -File ./test-local.ps1 -Act -Job tests
