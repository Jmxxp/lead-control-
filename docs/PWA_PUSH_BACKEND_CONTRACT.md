# Relatório diário via Web Push

## Responsabilidades

O navegador somente solicita permissão, mantém a assinatura Web Push e permite configurar a agenda. O cálculo do relatório e o disparo no horário configurado precisam acontecer no servidor. Service workers, páginas fechadas e APIs de sincronização periódica do navegador não oferecem um relógio confiável para esse agendamento.

O frontend usa `authenticatedRpc`, que acrescenta `p_session_token` a todos os contratos abaixo.

## RPCs consumidos pelo frontend

### `lc_get_push_public_key_v1()`

Retorna uma linha com a chave VAPID pública em Base64 URL-safe:

```json
{ "public_key": "B..." }
```

A chave deve representar um ponto P-256 não comprimido de 65 bytes. A chave privada nunca é enviada ao navegador.

### `lc_register_push_subscription_v1(p_subscription jsonb)`

Recebe a assinatura gerada pelo `PushManager`:

```json
{
  "endpoint": "https://push.example/...",
  "expiration_time": null,
  "keys": {
    "p256dh": "...",
    "auth": "..."
  },
  "content_encoding": "aes128gcm",
  "device": {
    "user_agent": "...",
    "language": "pt-BR",
    "timezone": "America/Sao_Paulo",
    "platform": "...",
    "display_mode": "standalone"
  }
}
```

O endpoint e as chaves são segredos operacionais: devem ficar em schema privado, nunca aparecer em listagens de UI nem em logs. O registro deve ser idempotente por endpoint e vinculado ao usuário autenticado.

### `lc_unregister_push_subscription_v1(p_endpoint text)`

Revoga somente um endpoint pertencente ao usuário autenticado. O frontend também chama `PushSubscription.unsubscribe()` no aparelho após a revogação remota.

### `lc_get_daily_report_settings_v1(p_store_id uuid)`

Retorna uma linha por agência ativa vinculada à loja e visível para a sessão:

```json
[
  {
    "store_id": "uuid",
    "store_name": "Loja Centro",
    "agency_user_id": "uuid",
    "agency_name": "Agência Exemplo",
    "enabled": true,
    "report_time": "18:00:00",
    "time_zone": "America/Sao_Paulo",
    "has_active_subscription": true,
    "next_run_at": "2026-09-10T21:00:00Z"
  }
]
```

Uma agência enxerga apenas a própria linha. A loja e o administrador podem receber todas as agências ativas daquela loja. Se ainda não houver configuração persistida, o backend deve retornar a associação com os defaults `enabled = false`, `report_time = 18:00` e um fuso válido.

### `lc_save_daily_report_setting_v1(...)`

Argumentos:

```text
p_store_id uuid
p_agency_user_id uuid
p_enabled boolean
p_report_time time
p_time_zone text
```

A agência só pode editar a própria associação. Loja e administrador podem editar uma agência ativa dentro do seu próprio escopo. O retorno recomendado é a linha salva com `has_active_subscription` e `next_run_at`; o frontend também aceita retorno vazio.

## Payload enviado ao service worker

```json
{
  "title": "Resumo diário · Loja Centro",
  "body": "R$ 4.760,00 vendidos · 18 prospecções · 27,8% de conversão",
  "tag": "daily-report-store-date",
  "data": {
    "url": "./?module=attendances",
    "storeId": "uuid",
    "reportDate": "2026-09-09"
  }
}
```

O service worker limita textos, ignora ícones fornecidos pelo servidor e só aceita URLs de destino da mesma origem e dentro do escopo do app. Ao tocar, ele foca uma janela existente ou abre o app. Ele não intercepta `fetch`, para não armazenar respostas autenticadas em cache.

## Agendamento e entrega

- A agenda deve usar `report_time` junto com o fuso IANA salvo, inclusive em mudanças de horário de verão.
- O job deve ser idempotente por loja, agência e data local do relatório.
- Assinaturas que retornarem HTTP `404` ou `410` devem ser revogadas.
- Falhas temporárias podem ser tentadas novamente com limite e backoff.
- O relatório deve calcular o fechamento do dia da loja no fuso configurado: valor vendido, total de prospecções e taxa de conversão.
- A entrega Web Push é por natureza “best effort”; `has_active_subscription` informa se existe ao menos um aparelho apto, não garante que o sistema operacional exibirá cada notificação.

## Restrições no celular

- HTTPS é obrigatório, exceto em `localhost` durante desenvolvimento.
- No iPhone/iPad, Web Push requer iOS/iPadOS 16.4 ou superior e o site instalado na Tela de Início.
- A permissão só é solicitada depois de um toque explícito em “Ativar neste aparelho”.
- Cada navegador/aparelho cria sua própria assinatura; desativar um aparelho não revoga automaticamente os demais.

Referências: [Push API (MDN)](https://developer.mozilla.org/en-US/docs/Web/API/Push_API) e [Web Push para apps na Tela de Início no iOS/iPadOS (WebKit)](https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/).
