# AllFLEXing — contrato de engenharia

Este arquivo é a referência normativa para qualquer agente ou pessoa que altere
este repositório. Ele deve ser suficiente por si só: não adicionar links nem
citar outros repositórios como justificativa. Quando código existente divergir
deste documento, este documento descreve o objetivo final e a divergência deve
ser corrigida ou explicitamente registrada aqui.

## 1. Escopo imutável

- O projeto é exclusivamente iOS. Não adicionar código, configuração ou
  documentação Android.
- O ambiente alvo é **sideload jailed comum**, com IPA assinada por certificado
  de developer e instalada/injetada pelo Feather.
- O alvo principal é **iOS 26**, **SDK 26.2** e **arm64**.
- Não depender de jailbreak, bootstrap, daemon, launch daemon, AppSync,
  TrollStore, TrollFools, rootless ou acesso fora do sandbox do app hospedeiro.
- Não adicionar caminhos `/var/jb`, `.jbroot`, `/Library/MobileSubstrate` ou
  outros caminhos de jailbreak ao artefato final.
- A assinatura final pertence ao app/IPA. O dylib pode receber assinatura ad-hoc
  durante o build, mas a IPA inteira precisa ser novamente assinada após a
  injeção.
- O produto do projeto é um único `AllFLEXing.dylib` contendo o FLEX completo,
  a camada antes chamada libFLEX, o loader, o runtime de hooks, a persistência e
  a interface. Não voltar a distribuir `FLEXing.dylib` e `libflex.dylib` como
  dois produtos separados.
- ElleKit é o provedor de hooks carregado pelo Feather dentro do app assinado.
  Ele não substitui a exigência de que FLEX e libFLEX estejam unificados dentro
  do `AllFLEXing.dylib`.

## 2. Contrato de build

O build deve seguir este formato básico:

```make
TARGET := iphone:clang:26.2:16.3
ARCHS = arm64
```

Regras obrigatórias:

- Usar Theos e `iphone:clang:26.2` de verdade; não apenas macros ou verificações
  de disponibilidade com um SDK antigo.
- O workflow deve baixar, armazenar em cache e validar especificamente
  `iPhoneOS26.2.sdk`.
- Antes de compilar, o workflow deve conferir a presença dos headers públicos de
  `UIGlassEffect` e `UIGlassContainerEffect` no SDK selecionado.
- Compilar todos os fontes necessários para FLEX, AllFLEXing e os módulos de
  runtime no mesmo target de tweak/dylib.
- Compilar a implementação namespaced de fishhook diretamente no target. Não
  depender de um fishhook já presente no app hospedeiro. Retirar esse fonte do
  glob amplo do FLEX e adicioná-lo exatamente uma vez pelo manifesto de
  providers.
- Manter manifestos separados para Core, HookProviders, HookRuntime e
  LiquidGlassUI, mas ligar todos no único target `AllFLEXing`.
- Compilar a integração estática das linhas de metadata como `.xm` com generator
  `MobileSubstrate`; nunca trocar essa integração pelo generator `internal`.
- Manter `-fobjc-arc` para o código Objective-C do projeto.
- Manter as definições `TARGET_OS_*` necessárias para os headers do SDK 26.2
  quando o toolchain do Theos não as fornecer corretamente.
- Usar `FINALPACKAGE=1` nos artefatos de distribuição e executar `ldid -S` no
  dylib final quando `ldid` estiver disponível.
- O install name do produto deve ser `@rpath/AllFLEXing.dylib`.
- Recursos indispensáveis ao runtime não podem depender de um arquivo solto que
  o injetor possa descartar. Dados pequenos e estáveis podem ser incorporados
  como fonte ou seção Mach-O; recursos de UI podem ficar num bundle somente se o
  fluxo de injeção e assinatura os validar.
- Tamanho do arquivo não é prova de integração. Validar classes, símbolos,
  slices, load commands e comportamento.

### 2.1 Integração Substrate-compatible/ElleKit

- Incluir o header Substrate-compatible no código que usa
  `MSHookMessageEx` e `MSHookFunction`.
- O target final não pode usar o generator `internal` como substituto do
  backend requerido. O generator interno do Logos cobre somente operações do
  runtime Objective-C e não fornece `%hookf` nem hook inline C.
- O artefato deve ser ligado contra a API Substrate-compatible de forma que o
  Feather possa instalar e redirecionar a dependência para o
  `CydiaSubstrate.framework` fornecido por ElleKit dentro de `Frameworks/`.
- A ordem de carregamento deve garantir que o provedor esteja disponível antes
  de instalar hooks que dependam dele.
- Em runtime, resolver e exibir o provedor real com `dladdr` sobre
  `MSHookMessageEx`/`MSHookFunction`. O texto da UI deve dizer `ElleKit` somente
  quando isso for comprovado.
- Se o provedor não estiver carregado, hooks que o exigem devem ficar
  indisponíveis com motivo claro. Nunca relatar sucesso usando apenas a presença
  de um nome de símbolo ou uma preferência persistida.
- Um fallback por runtime Objective-C pode existir para diagnóstico, mas deve
  ser identificado como modo degradado e não pode fingir equivalência com
  `MSHookMessageEx`.

## 3. Papel de cada tecnologia

### 3.1 Logos

- Logos é um preprocessor para hooks conhecidos em tempo de compilação.
- Usar Logos para hooks estáticos e declarativos que já fazem parte do produto.
- A integração conhecida com `FLEXMetadataSection` deve usar Logos para anexar a
  UI contextual. O alvo selecionado na linha continua sendo instalado
  dinamicamente pelo registry após validação de ABI.
- Não gerar dinamicamente código Logos para itens descobertos pelo Runtime
  Browser.
- `%ctor` é apropriado para registrar/bootstrapar código pequeno após o
  carregamento da imagem, mas não para construir a UI ou executar scans grandes.
- `%hookf` exige um backend compatível; não funciona no generator interno.
- O Runtime Browser deve chamar as APIs de hook diretamente, porque classe,
  selector, símbolo e ABI são escolhidos em runtime.

### 3.2 `MSHookMessageEx`

- Backend preferido para métodos Objective-C dinâmicos.
- Deve preservar exatamente um IMP original por alvo.
- Deve distinguir método de instância e método de classe. Para método de classe,
  o dispatch ocorre no metaclass.
- Antes da instalação, confirmar classe, selector, existência do `Method`, type
  encoding e perfil ABI suportado.
- Não criar cadeias duplicadas ao reaplicar ou reabrir a tela.

### 3.3 fishhook

- fishhook reescreve ponteiros de símbolos importados nas seções lazy/non-lazy
  do Mach-O.
- Ele não é um hook inline arbitrário e não substitui `MSHookFunction`.
- Um endereço retornado por `dlsym` não prova que existe um bind slot que
  fishhook possa trocar.
- Antes de oferecer fishhook, o resolver deve confirmar um import/bind pointer
  compatível no conjunto de imagens relevante.
- A implementação deve ser namespaced para evitar conflito com outra cópia no
  host.
- Guardar o ponteiro original e fazer o replacement encaminhá-lo quando o hook
  estiver desativado.

### 3.4 `MSHookFunction` via ElleKit

- Backend preferido para função C/C++ por endereço quando fishhook não se aplica
  e a ABI é conhecida.
- É um hook inline: altera a entrada da função e produz um trampoline para a
  implementação original.
- Exigir endereço válido, imagem conhecida, perfil ABI explícito, replacement
  compatível e ponteiro original não nulo após instalação.
- A instalação física é `install once`. Desligar um toggle não deve tentar
  restaurar instruções concorrendo com outras threads; o replacement passa a
  encaminhar imediatamente para o original.
- Não aplicar hook inline em endereço persistido cru. ASLR exige resolver o alvo
  novamente a cada processo.

### 3.5 Dobby

- Dobby pode ser implementado como provider experimental opcional, nunca como
  dependência implícita.
- Se adicionado, deve ser compilado de forma reproduzível para arm64, manter sua
  licença, ficar atrás da mesma interface de providers e possuir testes próprios.
- Não aplicar Dobby e ElleKit ao mesmo alvo.
- O modo `Auto` deve preferir ElleKit neste produto. Dobby só pode ser escolhido
  quando estiver realmente embarcado, validado e habilitado.

### 3.6 Swift e patches de dados

- Métodos Swift expostos ao runtime Objective-C podem seguir o caminho
  Objective-C após validação normal.
- Funções Swift puras não têm ABI inferível apenas pelo nome. Sem assinatura e
  endereço comprovados, mostrar como `Somente inspeção`.
- Patches arbitrários em `__TEXT` ou `__DATA` não fazem parte do primeiro
  contrato funcional.
- Scans de xrefs podem ser usados para descoberta, mas devem ser limitados,
  somente leitura e executados fora da main thread.

## 4. Matriz obrigatória de seleção do backend

| Superfície | Backend preferido | Condição de habilitação | Comportamento ao desligar |
|---|---|---|---|
| Método Objective-C | `MSHookMessageEx`/ElleKit | Classe, selector e ABI validados | Replacement encaminha ao IMP original |
| Símbolo C importado | fishhook | ABI explícita e bind slot confirmado | Replacement encaminha ao original |
| Função C por endereço | `MSHookFunction`/ElleKit | ABI explícita, imagem/endereço revalidados | Trampoline original é chamado |
| Hook estático conhecido | Logos + backend Substrate-compatible | Declarado no build e coberto por teste | Gate atômico dentro do hook |
| Método Swift `@objc` | Caminho Objective-C | Type encoding suportado | IMP original |
| Função Swift pura/desconhecida | Nenhum | Não habilitar sem ABI comprovada | Somente inspeção |
| Endereço sem símbolo/ABI | Nenhum | Não habilitar | Somente inspeção |

`Auto` deve escolher o backend usando a matriz, nunca por tentativa aleatória.
O usuário pode escolher outro backend somente se ele for válido para aquele
alvo. Opções inválidas aparecem desabilitadas com explicação.

## 5. Resolver de ABI

### 5.1 Regra geral

Descobrir um símbolo não equivale a descobrir sua assinatura. Nenhum hook pode
ser habilitado enquanto o registry não tiver um perfil ABI concreto e um stub
compatível.

Cada perfil deve declarar:

- convenção/superfície (`objc`, `c-import`, `c-inline`);
- tipo de retorno;
- quantidade e tipos dos argumentos;
- método de instância ou classe, quando aplicável;
- fábrica/slot do replacement;
- tipo do ponteiro original;
- backend permitido;
- capacidade de override, observação ou apenas listagem.

### 5.2 Objective-C

- Obter o `Method` real e seu `method_getTypeEncoding` no momento de `Apply` e
  novamente no lançamento seguinte.
- Contabilizar os argumentos ocultos `self` e `_cmd`.
- Validar separadamente retorno e cada argumento. Não converter um método para
  um stub `BOOL` só porque o nome começa com `is`, `has`, `can` ou `should`.
- A primeira versão dinâmica deve priorizar getters `BOOL` com zero argumentos
  explícitos e um conjunto pequeno de formas de um argumento já testadas.
- Cada forma suportada precisa de replacement ABI-matched. Não fazer cast de um
  único bloco/função para assinaturas diferentes.
- Métodos herdados exigem cuidado para não alterar a superclasse globalmente no
  fallback. No caminho principal, delegar esse tratamento ao provider.

### 5.3 C/C++

- Não existe type encoding C universal em runtime. O perfil deve vir de um
  catálogo curado, metadata incorporada ou escolha explícita do usuário.
- `dlsym` confirma resolução de nome/endereço, não assinatura.
- Para fishhook, confirmar também a existência do bind pointer importado.
- Para inline, registrar imagem, UUID quando disponível, nome do símbolo e
  offset relativo como locator; resolver o endereço atual antes de instalar.
- Não persistir ponteiros absolutos.
- Stubs devem possuir slots estáticos tipados, ponteiro original por alvo,
  estado atômico e contador atômico de chamadas.
- Se um perfil usar argumento/retorno de ponto flutuante, struct ou vetor, ele
  precisa de um stub específico e teste arm64. Caso contrário, manter desativado.

## 6. Registry como única fonte de verdade

O Runtime Browser, Hook Center, persistência, contadores e bootstrap devem usar
o mesmo registry. Não manter listas paralelas.

Cada entrada precisa, no mínimo, de:

- identificador estável;
- título e detalhe legíveis;
- tipo de alvo;
- locator serializável;
- perfil ABI;
- providers compatíveis e provider escolhido;
- `desiredEnabled`: intenção persistida;
- `pendingEnabled`: valor editado ainda não aplicado;
- `installed`: patch/IMP/rebind fisicamente instalado neste processo;
- `effectiveEnabled`: replacement atualmente forçando/observando;
- ponteiro original/trampoline somente em memória;
- número de chamadas/hits;
- data/geração da última validação;
- último erro e motivo de indisponibilidade;
- indicação `requiresRestart`.

Estados de UI não podem colapsar `desired`, `installed` e `effective` num único
booleano. Um toggle persistido não prova que o hook foi instalado.

## 7. Semântica de toggle e Apply

- Todo item realmente hookável descoberto no runtime deve ter um toggle ao lado.
- A mesma regra vale para métodos e propriedades BOOL exibidos no explorador de
  objetos padrão do FLEX, não somente para as telas separadas de Runtime Browser.
- O toggle contextual deve usar o mesmo ID, entrada, estado pendente, provider,
  contador e erro do Hook Center. É proibido recriar o dicionário de overrides
  isolado usado por protótipos anteriores.
- O menu contextual de uma linha hookável deve oferecer Force TRUE, Force FALSE,
  Forward Original, reaplicação daquela entrada, detalhes e Copy Hook ID.
- Itens sem ABI, provider ou locator seguro continuam visíveis, mas com toggle
  desabilitado e motivo concreto.
- Alterar um toggle contextual ou do Runtime Browser executa `stage + apply`
  somente para o ID daquela entrada. O switch deve mudar o comportamento em
  tempo real e nunca aplicar pendências não relacionadas. A instalação ocorre
  no handler da ação, nunca em `cellForRowAtIndexPath:` nem durante scroll.
- `pendingEnabled` continua necessário para edições de configuração, batch e
  recuperação de erro. O botão global `Aplicar` processa apenas o lote restante.
- O botão `Aplicar` executa uma transação:

  1. captura as mudanças pendentes;
  2. re-resolve cada alvo no processo atual;
  3. revalida ABI e capacidade do provider;
  4. instala uma única vez quando necessário;
  5. atualiza gates atômicos para efeito imediato;
  6. persiste somente estados validados;
  7. apresenta sucesso parcial/erro por entrada;
  8. atualiza resumo, hits e estado efetivo.

- Se uma entrada falhar, não marcá-la como ativa e não esconder o erro.
- Desligar deve ter efeito em tempo real pelo gate do replacement. Não tentar
  remover de modo inseguro hooks inline ou cadeias Objective-C em execução.
- `Aplicar e reiniciar` deve persistir, confirmar a gravação e então encerrar o
  processo somente após confirmação explícita. Um app jailed não pode se
  relançar sozinho; a UI deve instruir o usuário a abri-lo novamente.
- Se todas as mudanças forem aplicáveis ao vivo, `Aplicar` não deve exigir
  reinício artificialmente.

## 8. Persistência e recuperação

- Usar o `NSUserDefaults` padrão do app hospedeiro com prefixo exclusivo do
  AllFLEXing. Isso respeita o sandbox sem exigir App Group ou entitlement extra.
- Persistir locators e intenção, nunca IMPs, trampolines ou endereços absolutos.
- Persistir somente tipos property-list ou um payload versionado e validado.
- Alterações devem atualizar cache e storage de forma coerente e notificar a UI
  na main thread.
- No lançamento, reaplicar somente entradas exatas previamente persistidas.
  Não refazer um scan amplo e habilitar tudo que coincidir com heurística.
- Se classe, selector, imagem, símbolo ou ABI mudarem, marcar a entrada como
  `stale`/indisponível e não instalar.
- Implementar proteção contra crash loop:
  - registrar qual entrada estava sendo aplicada;
  - detectar inicialização anterior incompleta;
  - iniciar em safe mode quando necessário;
  - desabilitar apenas a entrada suspeita e mostrar diagnóstico recuperável.
- Mudanças de schema precisam de versão e migração explícita.

## 9. Timing de injeção

Deve existir um único bootstrap central.

Ordem esperada:

1. dyld carrega `AllFLEXing.dylib` e as dependências no app assinado;
2. o constructor cria o registry e detecta capabilities/providers;
3. registra hooks internos conhecidos e carrega locators persistidos;
4. reinstala apenas hooks persistidos seguros que precisam ocorrer cedo;
5. registra callbacks para imagens carregadas posteriormente quando necessário;
6. registra um observer descartável para `UIApplicationDidBecomeActive`;
7. na primeira ativação, re-resolve uma segunda vez classes/símbolos realizados
   tarde e remove o observer;
8. somente então registra na main thread a entrada global, gesto de abertura e
   camada visual;
9. callbacks de imagens posteriores continuam revalidando locators exatos sem
   duplicar hooks.

| Fase | Thread | Trabalho permitido | Objetivo |
|---|---|---|---|
| Image load | constructor/dyld | Flags, provider, hooks conhecidos e replay exato | Não perder chamadas iniciais |
| App ativa | main + fila serial | Replay tardio, registro da UI e gesto | Cobrir UIKit/Swift realizados tarde |
| Imagem tardia | callback mínimo + fila serial | Catalogar e revalidar entradas exatas | Suportar frameworks carregados depois |

Restrições:

- Constructor não pode criar view controllers, percorrer hierarquias de views,
  apresentar alertas ou executar scanner demorado.
- Scans de classes, Mach-O, símbolos e xrefs devem ocorrer em fila de background,
  com resultados entregues à main thread.
- Cada instalador deve ser idempotente e protegido por `dispatch_once`, registry
  ou lock apropriado.
- Não espalhar múltiplos constructors reaplicando os mesmos hooks.
- Imagens carregadas tarde devem atualizar o catálogo sem duplicar entradas e
  sem bloquear dyld callbacks com trabalho pesado.

## 10. Runtime Browser

### 10.1 Objective-C

- Enumerar classes e métodos por imagem, com busca e filtros.
- Mostrar classe, `+`/`-`, selector, type encoding, ABI normalizada, imagem e
  capacidade de hook.
- Permitir toggle somente para perfis reconhecidos.
- Ao aplicar, consultar novamente o runtime; o snapshot da lista não é prova de
  que o alvo continua igual.

### 10.2 C Runtime

- Enumerar imagens Mach-O, symbol table e imports/binds relevantes.
- Mostrar símbolo normalizado, imagem, endereço atual, `dladdr`, existência de
  bind slot, ABI escolhida e backends válidos.
- Oferecer `Observar`, `Forçar` ou `Somente inspeção` de acordo com o perfil.
- Resolver fishhook e inline separadamente. Não chamar fishhook de inline hook.
- Xref scanner, quando usado, deve limitar imagens/seções, validar bounds e
  permanecer somente leitura.

### 10.3 Estado compartilhado

- Um toggle acionado no Browser deve aparecer imediatamente no Hook Center.
- Um toggle acionado no explorador normal de propriedades/métodos também deve
  aparecer imediatamente no Hook Center e no Browser.
- O Hook Center deve abrir a mesma entrada no Browser para detalhes.
- Hits, erro, provider e estado efetivo são os mesmos objetos de estado, não
  cópias reconstruídas pela UI.

## 11. Hook Center profissional

A entrada global antiga de toggles deve evoluir para um Hook Center completo.

Estrutura mínima:

- **Resumo**: provider detectado, engines disponíveis, ativos, pendentes,
  falhas, safe mode e uptime do runtime.
- **Engines**: Auto, Objective-C/ElleKit, fishhook, inline/ElleKit e providers
  experimentais realmente compilados. Cada opção informa capacidade e status.
- **Pendentes**: alterações ainda não aplicadas, com `Aplicar` e
  `Descartar alterações`.
- **Ativos**: todos os hooks instalados, gate atual, backend, hits e acesso aos
  detalhes.
- **Browser Objective-C** e **C Runtime**: descoberta com busca, filtros e
  toggles ao lado de tudo que for seguro e hookável.
- **Explorador FLEX contextual**: métodos/propriedades BOOL hookáveis recebem
  `UISwitch` nativo e menu Runtime Hook sem perder navegação, detalhes ou copy.
- **Diagnóstico**: erros recentes, entradas stale, provider ausente e opção de
  exportar/copiar relatório.
- **Ações**: `Aplicar`, `Aplicar e reiniciar`, `Reabrir em safe mode` e limpeza
  seletiva de configuração. Ações destrutivas exigem confirmação.

Requisitos de interação:

- Usar diffable snapshots ou atualizações de tabela consistentes para evitar
  toggles associados à célula errada durante filtros.
- Identificar ações por ID estável da entrada, nunca apenas por index path.
- Exibir feedback háptico somente para uma mudança confirmada.
- `accessoryView` customizada precisa receber `frame`/`bounds` calculado pelo
  fitting size antes de ser entregue à célula. Auto Layout interno sozinho não
  dimensiona a accessory e causa switches sobrepostos ao texto.
- Desabilitar `Aplicar` quando não houver mudanças ou enquanto uma transação
  estiver em andamento.
- Mostrar progresso para scans e apply em lote, permitindo cancelamento antes
  da fase de instalação.
- Nunca bloquear a main thread com resolução de símbolos.

## 12. Liquid Glass no UIKit 26

Liquid Glass é hierarquia e comportamento, não apenas blur.

### 12.1 Regras de composição

- Recompilar com SDK 26.2 para que componentes UIKit padrão adotem o design
  atual automaticamente.
- Em iOS 26, remover appearances/backgrounds antigos de navigation bar e toolbar;
  uma aparência customizada opaca impede a adoção automática do material.
- Preferir `UINavigationBar`, `UIToolbar`, `UISearchBar`, menus, popovers,
  `UIButtonConfiguration` e `UISwitch` padrão.
- Glass pertence à camada flutuante de navegação e controles. Tabelas, células,
  código, logs e conteúdo permanecem na camada de conteúdo.
- Não aplicar glass em toda célula ou em todo fundo de tela.
- Não empilhar glass sobre glass.
- Controles customizados usam `UIVisualEffectView` com `UIGlassEffect`.
- Para um controle customizado interativo, usar o efeito interativo; para uma
  superfície puramente decorativa, não capturar toques.
- Botões independentes devem usar as configurações públicas `glass` ou
  `prominentGlass` conforme hierarquia da ação.
- `Aplicar` é ação principal e pode ser prominent glass; ações secundárias usam
  glass regular.
- `UISwitch` deve manter o visual nativo do iOS 26. Não desenhar um toggle falso
  dentro de outro painel glass.
- Geometria adaptativa deve usar `UICornerConfiguration`/`UICornerRadius` em
  iOS 26; `layer.cornerRadius` fica somente como fallback anterior.

### 12.2 Agrupamento e morphing

- Elementos glass relacionados devem compartilhar um
  `UIGlassContainerEffect`.
- O spacing do container determina quando os elementos começam a influenciar e
  fundir sua forma; escolher spacing coerente com o layout real.
- Para materializar/desmaterializar, animar a propriedade `effect` entre `nil`
  e `UIGlassEffect`. Não simular o material animando apenas `alpha`.
- Para merge/split, manter os elementos no mesmo container e animar seus frames
  até se sobreporem ou se separarem.
- Ao criar uma divisão, inserir os elementos inicialmente na mesma posição sem
  animação e então animá-los para posições distintas.
- Menus, popovers e action sheets devem informar corretamente o source view/item
  para que o UIKit forneça a transição/morphing nativo.
- Não animar continuamente toda a árvore do FLEX. Limitar morphing aos grupos de
  controles e mudanças de estado relevantes.

### 12.3 Acessibilidade e performance

- Respeitar Reduce Motion: substituir morphing complexo por transição curta e
  estável quando ativo.
- Usar APIs nativas para herdar Reduce Transparency, Increased Contrast e
  adaptação de cor.
- Manter labels legíveis, Dynamic Type, VoiceOver e áreas de toque adequadas.
- Não recriar efeitos em cada `layoutSubviews`; reutilizar views e atualizar
  apenas frame/configuração quando necessário.
- Em sistemas anteriores ao iOS 26, usar material UIKit simples como fallback,
  sem imitar de forma pesada o shader de Liquid Glass.

### 12.4 Arquitetura visual obrigatória

- É proibido instalar hook global em `UIViewController` para estilizar telas e
  é proibido percorrer recursivamente a árvore de views procurando nomes de
  classes. Aparência é responsabilidade explícita do controller ou componente
  que cria a superfície.
- A entrada global abre um workspace próprio. Em largura compacta ele usa tab
  bar flutuante; em largura regular usa o modo tab/sidebar adaptativo do UIKit.
  Center, Objective-C, C Runtime e Settings mantêm navigation controllers
  independentes e compartilham o mesmo registry.
- O Hook Center usa header auto-dimensionável, métricas que mudam de linha em
  largura compacta ou categoria de texto de acessibilidade, conteúdo de lista
  nativo e `UIBarButtonItem` proeminente para Apply.
- Ações secundárias ficam em `UIMenu` ligado ao item que as originou. Escopo do
  scanner, popovers e action sheets sempre informam seu source item/view para o
  UIKit executar continuidade e morphing.
- O seletor horizontal de hierarquia do FLEX contém uma única seleção
  `UIGlassEffect` dentro de um `UIGlassContainerEffect`. A seleção muda de forma
  animando o frame entre os atributos reais do collection layout; as labels
  continuam na camada de conteúdo.
- A toolbar flutuante do explorer é uma superfície glass explícita. O painel de
  descrição materializa e desmaterializa animando `effect`; nenhuma rotina
  posterior tenta inserir backdrops por heurística.
- O submódulo FLEX permanece fixado em commit conhecido. Alterações de
  apresentação indispensáveis são armazenadas num patch versionado, verificadas
  e aplicadas idempotentemente antes do build. O build deve falhar se a base não
  corresponder ao patch, em vez de produzir UI parcialmente aplicada.
- Tamanhos fixos legados de toolbar não são usados no iOS 26. Layout usa métricas
  do sistema, safe areas, readable width, fitting size, Dynamic Type e
  `setContentScrollView:forEdge:` para adaptação de scroll edges e minimização
  nativas.

## 13. Análise do binário de referência

Os binários fornecidos confirmam a arquitetura de produto que deve ser
preservada:

- FLEX e a antiga camada libFLEX estão compilados na mesma imagem;
- classes do explorer, manager, toolbar, browser e utilitários estão presentes;
- exports de compatibilidade da antiga libFLEX continuam disponíveis;
- fishhook está incorporado;
- existem loader, persistência, toggles e helper visual próprios;
- a referência mais recente inclui `FLEXRuntimeHookActions`, ações TRUE/FALSE e
  integração contextual em `FLEXMetadataSection`, mas limita o resolver a
  getters BOOL sem argumento explícito;
- `MSHookMessageEx` é importado do framework provider; o item local chamado
  `MSHookFunction` na referência é um ponteiro resolvido em `__bss`, não o
  backend inline incorporado;
- a referência mais recente possui aproximadamente 1,6 MB de `__LINKEDIT`,
  símbolos locais e caminhos de objetos de um build debug;
- o disassembly integral da referência cobre todas as três seções executáveis,
  299.875 linhas, bytes brutos, símbolos e destinos/xrefs de branches;
- essa referência declara minimum OS 15.0 e SDK 16.5. Portanto seu helper visual
  não é prova de uso nativo das APIs do SDK 26.2;
- o tamanho maior decorre de debug, falta de otimização e, no binário anterior,
  múltiplos slices; portanto não é uma medida confiável de funcionalidade.

Usar o binário para conferir compatibilidade e composição, não para copiar
endereços, presumir ABI ou substituir build reproduzível por engenharia reversa.

## 14. Verificação obrigatória do artefato

O build só está concluído quando passar por validação estática e runtime.

### 14.1 Estática

- `file`/`lipo`: `MH_DYLIB`, arm64 esperado e nenhum slice acidental.
- `vtool -show-build` ou `otool -l`: SDK 26.2 e deployment target esperado.
- `otool -D`: install name `@rpath/AllFLEXing.dylib`.
- `otool -L`: dependências do sistema e framework Substrate-compatible que o
  Feather consegue redirecionar para ElleKit.
- `otool -l`/`strings`: ausência de rpaths e paths de jailbreak.
- `nm`/metadata Objective-C: classes completas do FLEX, classes AllFLEXing,
  registry, resolver ABI, `FLEXRuntimeHookActions`, Hook Center e exports de
  compatibilidade.
- `nm -u`/imports: chamadas `MSHookMessageEx` e `MSHookFunction` presentes quando
  o provider é obrigatório.
- classrefs/strings: APIs reais `UIGlassEffect` e `UIGlassContainerEffect`.
- confirmar que fishhook foi incorporado uma única vez, com namespace e com os
  exports marcadores `FLEXEmbeddedFishhookAvailable` e ABI versionada.
- confirmar que o fishhook usa `vm_protect` com `VM_PROT_COPY`, não escreve após
  falha de proteção e só relata sucesso quando ao menos um bind slot foi trocado.
- confirmar que as ações contextuais TRUE/FALSE/Apply e a integração Logos foram
  compiladas.
- confirmar que o dylib não depende de um segundo `libflex.dylib` ou
  `FLEXing.dylib`.

### 14.2 Runtime em IPA assinada

- Instalar pelo fluxo Feather com certificado de developer em dispositivo iOS
  26 arm64.
- Confirmar que a IPA abre sem jailbreak e que o `AllFLEXing.dylib` é carregado.
- Confirmar por `dladdr` que o provider dos MSHook APIs é ElleKit.
- Testar método Objective-C de instância, de classe, getter `BOOL` e perfil de um
  argumento.
- Testar símbolo C importado com fishhook.
- Testar função C conhecida por endereço com `MSHookFunction` e trampoline.
- Em todos os casos: ligar, aplicar, observar hits, desligar e comprovar retorno
  imediato ao original.
- Reiniciar manualmente o app e confirmar persistência por locator re-resolvido.
- Carregar uma imagem tarde e confirmar atualização sem hook duplicado.
- Simular provider ausente, ABI alterada e alvo ausente; todos devem falhar
  fechados e explicar o motivo.
- Validar safe mode após uma aplicação intencionalmente interrompida.
- Validar Liquid Glass, morphing, menus ancorados, Reduce Motion, contraste,
  orientação e diferentes tamanhos de tela.

## 15. Critérios de aceite

Uma entrega não pode ser descrita como concluída até que:

- produza um único `AllFLEXing.dylib` unificado;
- o Mach-O reporte SDK 26.2 e arm64;
- o build e workflow sejam reproduzíveis;
- Feather injete a API Substrate-compatible usando ElleKit no app jailed;
- `MSHookMessageEx`, fishhook e `MSHookFunction` tenham testes reais;
- o resolver nunca habilite uma entrada com ABI desconhecida;
- todo alvo hookável no Browser possua toggle;
- todo método/propriedade BOOL hookável no explorador FLEX possua o mesmo toggle
  contextual e entrada de registry;
- Apply revalide e instale de forma idempotente;
- toggles desligados encaminhem ao original em tempo real;
- persistência sobreviva ao relançamento sem salvar ponteiros absolutos;
- o Hook Center reúna pendentes, ativos, provider, hits e erros;
- a UI use componentes UIKit 26 e Liquid Glass sem glass-on-glass;
- morphing use container/effect/frame, respeitando acessibilidade;
- não existam paths, dependências ou pressupostos de jailbreak.

## 16. Estado atual e validações ainda obrigatórias

A base implementada já inclui target `iphone:clang:26.2:16.3`, arm64, dylib
unificada, provider Substrate-compatible validado, `MSHookMessageEx`, fishhook,
`MSHookFunction`, manifestos explícitos de providers, integração Logos das
linhas de metadata, `FLEXRuntimeHookActions`, registry persistente por locators,
safe mode, Runtime Browser, Hook Center e a camada visual UIKit 26 descrita
neste arquivo. Capacidades de `MSHookMessageEx` e `MSHookFunction` são medidas
separadamente. Toggles contextuais aplicam uma entrada imediatamente, o fishhook
local usa a proteção moderna de `__DATA_CONST`, e o bootstrap possui fases de
image load, primeira ativação e imagem tardia. O monitor de imagens carregadas
tarde apenas agenda rescan e reaplicação idempotente fora do callback do loader.

Compilação e inspeção estática não substituem as seguintes validações finais:

- executar a matriz da seção 14 em aparelho iOS 26 com IPA assinada por
  certificado de desenvolvedor;
- confirmar em runtime que o provider carregado é ElleKit e que cada trampoline
  preserva o original;
- testar carregamento tardio real, debounce, rescan e ausência de hook duplicado;
- validar safe mode após interrupção intencional durante Apply;
- fazer QA visual e de acessibilidade do Liquid Glass em aparelho, incluindo
  morphing, Reduce Motion, contraste, rotação e tamanhos de tela;
- ampliar o catálogo ABI somente junto de stubs tipados e testes equivalentes;
- medir o custo de scans amplos e ajustar limites sem executar trabalho pesado
  no callback do loader.

## 17. Disciplina de alteração

- Não copiar subsistemas inteiros sem entender ownership, timing e ABI.
- Não adicionar outro registry, outra persistência ou outro bootstrap paralelo.
- Não declarar sucesso com base apenas em compilação, tamanho ou strings.
- Não reduzir segurança para aumentar a quantidade de toggles: entradas
  desconhecidas continuam visíveis como inspeção, nunca como hooks falsos.
- Toda nova ABI precisa de stub e teste correspondente.
- Todo novo provider precisa de capability detection, licença, build
  reproduzível, diagnóstico e testes.
- Toda mudança visual precisa respeitar a separação conteúdo/controles e as
  adaptações de acessibilidade.
- Atualizar este arquivo quando uma decisão arquitetural mudar.
