```sh
go get {{GO_MODULE}}@v{{VERSION}}
```

```go
import {{API_IDENT}}sdk "{{GO_MODULE}}"

cfg := {{API_IDENT}}sdk.NewConfiguration()
client := {{API_IDENT}}sdk.NewAPIClient(cfg)
ctx := context.WithValue(context.Background(), {{API_IDENT}}sdk.ContextAccessToken, os.Getenv("VEILPLANE_TOKEN"))
```

From major version 2 on, the module path ends with the major version (`…/v2`), as Go requires.
