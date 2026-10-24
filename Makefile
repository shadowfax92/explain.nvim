# Each spec file runs in its own Neovim so screen state, autocmds and the
# working directory cannot leak between files. FILTER=marks runs one file.
test:
	@status=0; for spec in tests/*_spec.lua; do \
		case "$$spec" in *"$(FILTER)"*) nvim --clean --headless -l tests/run.lua "$$spec" || status=1;; esac; \
	done; exit $$status
