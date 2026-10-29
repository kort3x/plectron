# Runs before every tool (and before Plectron reads the module). Use it for
# environment the tools expect: variables, extra module paths, defaults.
$env:CONTOSO_ENVIRONMENT = 'demo'
$PSDefaultParameterValues['Test-Port:TimeoutMs'] = 1500
