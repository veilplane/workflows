Maven:

```xml
<dependency>
  <groupId>com.veilplane</groupId>
  <artifactId>vp-{{API}}-sdk</artifactId>
  <version>{{VERSION}}</version>
</dependency>
```

Gradle: `implementation("com.veilplane:vp-{{API}}-sdk:{{VERSION}}")`

```java
var client = new com.veilplane.sdk.{{API_IDENT}}.ApiClient();
client.setRequestInterceptor(r -> r.header("Authorization", "Bearer " + System.getenv("VEILPLANE_TOKEN")));
```

Java 11 or later; it uses the JDK's own HTTP client.
