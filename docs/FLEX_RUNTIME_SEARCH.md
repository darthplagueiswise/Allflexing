# Pesquisa Objective-C no AllFLEXing

A tela **Hookable Objective-C** usa a infraestrutura do próprio FLEX para ler o
runtime: `FLEXRuntimeClient`, `FLEXRuntimeController`, `FLEXMethod`,
`FLEXProperty`, `FLEXMetadataSection` e a navegação do Runtime Browser.
AllFLEXing acrescenta somente o filtro de hookabilidade, o estado pending,
Apply, ABI e persistência.

## Busca normal — modo recomendado

Não é necessário usar símbolos especiais. Digite nomes ou palavras em qualquer
ordem.

Estas formas são equivalentes:

- `FBConfigManager`
- `fbconfigmanager`
- `fb config manager`
- `fb_config_manager`

Estas também são equivalentes:

- `employee enable`
- `employeeenable`
- `enable employee`

A consulta usa semântica AND: todos os termos precisam aparecer em algum campo
do mesmo resultado. Os campos pesquisados incluem nome da classe, selector,
descrição produzida pelo FLEX, type encoding e imagem.

CamelCase, snake_case, pontuação, espaços e a forma compacta são normalizados.
Consultas de um único caractere também são aceitas.

## Sintaxe avançada do FLEX

A sintaxe original continua disponível ao digitar explicitamente `.`, `*`, `\`
ou iniciar a consulta com `+` ou `-`.

- `.` separa os componentes **imagem . classe . método**.
- `*` significa qualquer trecho/wildcard.
- `-` antes do método limita o resultado a **método de instância**.
- `+` antes do método limita o resultado a **método de classe**.
- `\` escapa um caractere que seria interpretado como parte da gramática.

Exemplos:

- `*.FBConfigManager.*` — qualquer imagem, classe `FBConfigManager`, qualquer método.
- `*.*.-isEnabled` — qualquer imagem e classe, somente o método de instância `-isEnabled`.
- `*.*.+sharedInstance` — qualquer imagem e classe, somente o método de classe `+sharedInstance`.

Em Objective-C, `-` e `+` não indicam valor negativo ou positivo:

```objc
- (BOOL)isEnabled;       // chamado em uma instância
+ (id)sharedInstance;    // chamado na própria classe
```

A interface possui um botão `?` com esta explicação. A barra adicional de
símbolos do FLEX foi ocultada na tela filtrada porque a busca normal é o fluxo
principal.

## Filtro de hookabilidade

A tela não mostra todo o metadata lido pelo FLEX. Ela remove métodos e
propriedades que o backend atual não consegue representar com segurança.
Classes sem nenhum método hookável desaparecem do resultado.

Para Objective-C, a inferência automática aceita somente retorno `BOOL` com
encoding exato `B`. Encodings `c` e `C` são `char`, não BOOL.

O switch apenas altera o estado pending. O hook físico só é instalado por
**Apply This Hook** ou pelo Apply do lote.
