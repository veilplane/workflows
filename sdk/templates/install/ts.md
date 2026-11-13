```sh
npm install @veilplane/{{API}}-sdk
```

```ts
import { Configuration } from "@veilplane/{{API}}-sdk";

const config = new Configuration({ accessToken: process.env.VEILPLANE_TOKEN });
```

The package uses the platform's `fetch` (Node.js 18 and later, Deno, Bun, browsers).
