#!/do/not/make
#^^^ help emacs select edit mode
#
# Intended to include'd by ./GNUmakefile.
#######################################################################

########################################################################
# shell.c and its build flags...
ifneq (1,$(MAKING_CLEAN))
  make-np-0 = make -C  $(dir.top) -n -p
  make-np-1 = sed -e 's/(TOP)/(dir.top)/g'
  # Extract SHELL_OPT and SHELL_DEP from the top-most makefile and import
  # them as vars here...
  $(eval $(shell $(make-np-0) | grep -e '^SHELL_OPT ' | $(make-np-1)))
  $(eval $(shell $(make-np-0) | grep -e '^SHELL_DEP ' | $(make-np-1)))
  # ^^^ can't do that in 1 invocation b/c newlines get stripped
  ifeq (,$(SHELL_OPT))
  $(error Could not parse SHELL_OPT from $(dir.top)/Makefile.)
  endif
  ifeq (,$(SHELL_DEP))
  $(error Could not parse SHELL_DEP from $(dir.top)/Makefile.)
  endif
$(dir.top)/shell.c: $(SHELL_DEP) $(dir.tool)/mkshellc.tcl $(sqlite3.c)
	$(MAKE) -C $(dir.top) shell.c
endif
# /shell.c
########################################################################

EXPORTED_FUNCTIONS.fiddle = $(dir.tmp)/EXPORTED_FUNCTIONS.fiddle
fiddle.emcc-flags = \
  $(emcc.cflags) $(emcc_opt_full) \
  --minify 0 \
  -sALLOW_TABLE_GROWTH \
  -sABORTING_MALLOC \
  -sSTRICT_JS=0 \
  -sENVIRONMENT=web,worker \
  -sMODULARIZE \
  -sDYNAMIC_EXECUTION=0 \
  -sWASM_BIGINT=$(emcc.WASM_BIGINT) \
  -sEXPORT_NAME=$(sqlite3.js.init-func) \
  -Wno-limited-postlink-optimizations \
  $(emcc.exportedRuntimeMethods),FS \
  -sEXPORTED_FUNCTIONS=@$(abspath $(EXPORTED_FUNCTIONS.fiddle)) \
  $(SQLITE_OPT.full-featured) \
  $(SQLITE_OPT.common) \
  $(SHELL_OPT) \
  -UHAVE_READLINE -UHAVE_EDITLINE -UHAVE_LINENOISE \
  -USQLITE_HAVE_ZLIB \
  -USQLITE_WASM_BARE_BONES \
  -DSQLITE_SHELL_FIDDLE

# Flags specifically for debug builds of fiddle. Performance suffers
# greatly in debug builds.
fiddle.emcc-flags.debug = $(fiddle.emcc-flags) \
  -DSQLITE_DEBUG \
  -DSQLITE_ENABLE_SELECTTRACE \
  -DSQLITE_ENABLE_WHERETRACE

fiddle.EXPORTED_FUNCTIONS.in = \
    EXPORTED_FUNCTIONS.fiddle.in \
    $(dir.api)/EXPORTED_FUNCTIONS.sqlite3-core \
    $(dir.api)/EXPORTED_FUNCTIONS.sqlite3-extras

$(EXPORTED_FUNCTIONS.fiddle): $(MKDIR.bld) $(fiddle.EXPORTED_FUNCTIONS.in) \
    $(MAKEFILE.fiddle)
	sort -u $(fiddle.EXPORTED_FUNCTIONS.in) > $@

fiddle.cses = $(dir.top)/shell.c $(sqlite3-wasm.c)

clean: clean-fiddle
clean-fiddle:
	rm -f $(dir.fiddle)/fiddle-module.js \
        $(dir.fiddle)/*.wasm \
        $(dir.fiddle)/sqlite3-opfs-*.js \
        $(dir.fiddle)/*.gz \
        EXPORTED_FUNCTIONS.fiddle
	rm -fr $(dir.fiddle-debug)
.PHONY: fiddle fiddle.debug
all: fiddle

########################################################################
# fiddle_remote is the remote destination for the fiddle app. It must
# be a [user@]HOST:/path for rsync.  The target "should probably"
# contain a symlink of index.html -> fiddle.html.
fiddle_remote ?=
ifeq (,$(fiddle_remote))
ifneq (,$(wildcard /home/stephan))
  fiddle_remote = wh:www/wasm-testing/fiddle/.
else ifneq (,$(wildcard /home/drh))
  #fiddle_remote = if appropriate, add that user@host:/path here
endif
endif
push-fiddle: fiddle
	@if [ x = "x$(fiddle_remote)" ]; then \
		echo "fiddle_remote must be a [user@]HOST:/path for rsync"; \
		exit 1; \
	fi
	rsync -va fiddle/ $(fiddle_remote)
# end fiddle remote push
########################################################################


########################################################################
# Explanation of the emcc build flags follows. Full docs for these can
# be found at:
#
#  https://github.com/emscripten-core/emscripten/blob/main/src/settings.js
#
# -sENVIRONMENT=web: elides bootstrap code related to non-web JS
#  environments like node.js. Removing this makes the output a tiny
#  tick larger but hypothetically makes it more portable to
#  non-browser JS environments.
#
# -sMODULARIZE: changes how the generated code is structured to avoid
#  declaring a global Module object and instead installing a function
#  which loads and initializes the module. The function is named...
#
# -sEXPORT_NAME=jsFunctionName (see -sMODULARIZE)
#
# -sEXPORTED_RUNTIME_METHODS=@/absolute/path/to/file: a file
#  containing a list of emscripten-supplied APIs, one per line, which
#  must be exported into the generated JS. Must be an absolute path!
#
# -sEXPORTED_FUNCTIONS=@/absolute/path/to/file: a file containing a
#  list of C functions, one per line, which must be exported via wasm
#  so they're visible to JS. C symbols names in that file must all
#  start with an underscore for reasons known only to the emcc
#  developers. e.g., _sqlite3_open_v2 and _sqlite3_finalize. Must be
#  an absolute path!
#
# -sSTRICT_JS ensures that the emitted JS code includes the 'use
#  strict' option. Note that -sSTRICT is more broadly-scoped and
#  results in build errors.
#
# -sALLOW_TABLE_GROWTH is required for (at a minimum) the UDF-binding
#  feature. Without it, JS functions cannot be made to proxy C-side
#  callbacks.
#
# -sABORTING_MALLOC causes the JS-bound _malloc() to abort rather than
#  return 0 on OOM. If set to 0 then all code which uses _malloc()
#  must, just like in C, check the result before using it, else
#  they're likely to corrupt the JS/WASM heap by writing to its
#  address of 0. It is, as of this writing, enabled in Emscripten by
#  default but we enable it explicitly in case that default changes.
#
# -sDYNAMIC_EXECUTION=0 disables eval() and the Function constructor.
#  If the build runs without these, it's preferable to use this flag
#  because certain execution environments disallow those constructs.
#  This flag is not strictly necessary, however.
#
# --no-entry: for compiling library code with no main(). If this is
#  not supplied and the code has a main(), it is called as part of the
#  module init process. Note that main() is #if'd out of shell.c
#  (renamed) when building in wasm mode.
#
# --pre-js/--post-js=FILE relative or absolute paths to JS files to
#  prepend/append to the emcc-generated bootstrapping JS. It's
#  easier/faster to develop with separate JS files (reduces rebuilding
#  requirements) but certain configurations, namely -sMODULARIZE, may
#  require using at least a --pre-js file. They can be used
#  individually and need not be paired.
#
# -O0..-O3 and -Oz: optimization levels affect not only C-style
#  optimization but whether or not the resulting generated JS code
#  gets minified. -O0 compiles _much_ more quickly than -O3 or -Oz,
#  and doesn't minimize any JS code, so is recommended for
#  development. -O3 or -Oz are recommended for deployment, but
#  primarily because -Oz will shrink the wasm file notably. JS-side
#  minification makes little difference in terms of overall
#  distributable size.
#
# --minify 0: supposedly disables minification of the generated JS
#  code, regardless of optimization level, but that's not quite true:
#  search the main makefile for wasm-strip for details. Minification
#  of the JS has minimal overall effect in the larger scheme of things
#  and results in JS files which can neither be edited nor viewed as
#  text files in Fossil (which flags them as binary because of their
#  extreme line lengths). Interestingly, whether or not the comments
#  in the generated JS file get stripped is unaffected by this setting
#  and depends entirely on the optimization level. Higher optimization
#  levels reduce the size of the JS considerably even without
#  minification.
#
########################################################################
