# :elixir_make entry on Nerves targets: builds the dashboard into
# priv/static, which the gateway serves at /.

STATIC := priv/static/index.html
SOURCES := $(shell find dashboard/src ../ovcs_ui/vue -type f) \
	$(wildcard dashboard/*.js dashboard/*.json dashboard/index.html) \
	$(wildcard ../ovcs_ui/*.css ../ovcs_ui/*.js ../ovcs_ui/package.json)

all: $(STATIC)

$(STATIC): $(SOURCES)
	cd dashboard && npm ci && npm run build

clean:
	rm -rf priv/static

.PHONY: all clean
