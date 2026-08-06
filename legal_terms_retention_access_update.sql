-- Controle de Leads + Prospecções
-- Atualização incremental: licenças, exportação pós-downgrade, retenção de
-- dois anos e aceite versionado dos Termos de Uso.
-- Rode este arquivo uma única vez no SQL Editor do Supabase.

begin;

set local search_path = public, extensions;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists app_private;

-- --------------------------------------------------------------------------
-- TERMOS DE USO VERSIONADOS E EVIDÊNCIA DE ACEITE
-- --------------------------------------------------------------------------

create table if not exists public.system_legal_terms (
  id uuid primary key default gen_random_uuid(),
  version text not null unique,
  title text not null,
  content text not null,
  content_hash text not null,
  effective_at timestamptz not null default now(),
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  check (length(btrim(version)) > 0),
  check (length(btrim(title)) > 0),
  check (length(btrim(content)) > 0)
);

create unique index if not exists system_legal_terms_one_active_uidx
  on public.system_legal_terms (is_active)
  where is_active = true;

create table if not exists public.legal_term_acceptances (
  id uuid primary key default gen_random_uuid(),
  terms_id uuid not null references public.system_legal_terms(id) on delete restrict,
  terms_version text not null,
  terms_title text not null,
  terms_snapshot text not null,
  terms_hash text not null,
  admin_user_id uuid not null references public.app_users(id) on delete cascade,
  accepting_user_id uuid references public.app_users(id) on delete set null,
  account_role public.app_user_role not null,
  account_name_snapshot text not null,
  agency_name_snapshot text,
  store_name_snapshot text,
  signer_name text not null,
  signer_role text not null,
  signer_cpf_hash text not null,
  signer_cpf_last4 text not null,
  signature_data_url text not null,
  signature_hash text not null,
  confirmations jsonb not null default '[]'::jsonb,
  ip_address text,
  user_agent text,
  client_timezone text,
  client_timestamp timestamptz,
  accepted_at timestamptz not null default now(),
  evidence_hash text not null,
  unique (terms_id, accepting_user_id),
  check (length(btrim(signer_name)) >= 3),
  check (length(btrim(signer_role)) >= 2),
  check (signer_cpf_last4 ~ '^[0-9]{4}$'),
  check (signature_data_url like 'data:image/png;base64,%')
);

create index if not exists legal_term_acceptances_admin_date_idx
  on public.legal_term_acceptances (admin_user_id, accepted_at desc);
create index if not exists legal_term_acceptances_user_date_idx
  on public.legal_term_acceptances (accepting_user_id, accepted_at desc);

alter table public.system_legal_terms enable row level security;
alter table public.legal_term_acceptances enable row level security;

update public.system_legal_terms
set is_active = false
where is_active = true
  and version <> '2026.08.05-4';

insert into public.system_legal_terms (
  version,
  title,
  content,
  content_hash,
  effective_at,
  is_active
)
values (
  '2026.08.05-4',
  'Termos de Uso, Privacidade e Licença da Plataforma',
  $terms$
## 1. Partes, finalidade e aceite
Estes Termos regulam o acesso à plataforma de Controle de Leads e Prospecções (“Plataforma”) pelo usuário, pela empresa cliente e, quando aplicável, pela agência responsável. O fornecedor e licenciante da Plataforma é JOAO MARCOS DIAS PAINA JUNIOR, pessoa física inscrita no CPF sob o nº 532.222.238-31, telefone (19) 99637-0701 e e-mail muitofacil18@gmail.com (“Fornecedor”). Ao assinar eletronicamente, o usuário confirma que leu, compreendeu e aceita integralmente estes Termos e que possui capacidade e poderes para vincular a conta e a organização que representa.

## 2. Objeto e licença limitada
A Plataforma disponibiliza recursos de cadastro, organização, análise, acompanhamento e exportação de leads e prospecções. É concedida licença temporária, revogável, não exclusiva, intransferível e limitada ao uso interno da organização autorizada, durante a vigência do plano contratado. Nenhum direito sobre código-fonte, arquitetura, identidade visual, fluxos, métodos, modelos de dados, documentação, lógica de negócio ou tecnologia é transferido ao usuário.

## 3. Contas, credenciais e usuários autorizados
Cada acesso é pessoal e deve ser utilizado exclusivamente pela pessoa ou equipe expressamente autorizada. É proibido vender, ceder, sublicenciar, emprestar, compartilhar credenciais ou permitir acesso a terceiros sem autorização formal. O titular da conta responde por manter senha e dispositivos seguros, encerrar sessões em equipamentos compartilhados e informar imediatamente qualquer suspeita de uso indevido.

## 4. Hierarquia de acesso e confidencialidade
Os dados de cada cliente permanecem segregados por conta. Podem acessá-los: o próprio cliente autorizado; a agência vinculada àquele cliente, para execução dos serviços contratados; e o Admin, para administração, suporte, segurança, auditoria e operação da Plataforma. Usuários não podem acessar contas fora de seu escopo. Todos os envolvidos devem preservar confidencialidade e utilizar os dados apenas para as finalidades profissionais autorizadas.

## 5. Proteção de dados pessoais e LGPD
As partes comprometem-se a observar a Lei nº 13.709/2018 (LGPD), incluindo finalidade, adequação, necessidade, transparência, segurança, prevenção e prestação de contas. Em regra, o cliente e/ou a agência que decide quais dados inserir e para quais finalidades atua como controlador; o fornecedor da Plataforma atua como operador nos limites das instruções e da prestação tecnológica, sem prejuízo das responsabilidades específicas que a lei atribuir a cada parte.

- O usuário deve possuir base legal válida para cadastrar e tratar dados de leads, clientes, funcionários e demais titulares.
- Devem ser inseridos apenas dados necessários à finalidade comercial legítima e informada.
- Solicitações de titulares devem ser encaminhadas imediatamente ao responsável pela conta e tratadas conforme a LGPD.
- É proibido inserir dados obtidos de forma ilícita, discriminatória, enganosa ou incompatível com a finalidade declarada.
- A assinatura desenhada, o identificador da conta e as evidências do aceite são tratados para autenticação, execução contratual, prevenção a fraude e exercício regular de direitos.

## 6. Compartilhamento e infraestrutura Supabase
Os dados não são vendidos, alugados nem compartilhados para publicidade de terceiros. O acesso funcional fica restrito ao usuário autorizado, ao Admin e à agência vinculada, conforme a hierarquia da conta. Poderá ocorrer tratamento técnico por fornecedores essenciais de infraestrutura, especialmente o Supabase, utilizado para banco de dados, autenticação, disponibilidade e recursos de segurança, além de divulgação quando exigida por lei, ordem judicial ou autoridade competente.

A segurança opera em modelo de responsabilidade compartilhada. A Plataforma depende da disponibilidade e da arquitetura de segurança do Supabase, do qual o fornecedor é cliente, e também das configurações, controles de acesso e código mantidos pelo fornecedor da Plataforma. Essa dependência não elimina obrigações legais inderrogáveis, mas eventos exclusivamente causados pela infraestrutura de terceiros serão apurados conforme a participação e a responsabilidade de cada agente.

## 7. Segurança e incidentes
São adotadas medidas técnicas e administrativas compatíveis com a natureza do serviço, incluindo segregação lógica, autenticação, restrição de acesso e trilha de evidências. Nenhum sistema é absolutamente imune a falhas. O usuário deve colaborar com investigações, preservar evidências e comunicar incidentes. Incidentes com risco ou dano relevante serão tratados e comunicados nos termos aplicáveis da LGPD.

## 8. Retenção, exportação e exclusão
Os registros operacionais de Prospecções são mantidos por uma janela móvel máxima de 2 (dois) anos contada da criação de cada registro. Dados mais antigos são eliminados automaticamente para dar lugar aos registros novos, salvo obrigação legal, ordem de preservação ou necessidade legítima de exercício de direitos. O cliente deve realizar exportações periódicas quando precisar manter histórico próprio por prazo superior.

Se o acesso ao módulo Prospecções for desativado, a operação e a visualização analítica ficam bloqueadas, mas a conta poderá exportar os registros ainda existentes durante a janela de retenção. A reativação não recupera dados que já tenham sido eliminados pela política de dois anos. Evidências de aceite, auditoria, segurança e documentos contratuais podem ser conservados por prazo distinto quando necessários ao cumprimento de obrigação legal ou ao exercício regular de direitos.

## 9. Propriedade intelectual e uso restrito
Todos os direitos sobre a Plataforma, incluindo software, interfaces, design, fluxos, automações, lógica de registro, organização, facilitação de uso, relatórios, documentação, marcas, segredos de negócio e melhorias pertencem ao fornecedor ou a seus licenciantes. O usuário não poderá copiar, reproduzir, adaptar, traduzir, desmontar, descompilar, realizar engenharia reversa, extrair código, contornar controles, criar obra derivada ou explorar elemento substancial da Plataforma, salvo autorização escrita ou hipótese legal que não possa ser afastada contratualmente.

## 10. Não concorrência por uso indevido e não aproveitamento parasitário
Durante o acesso e por 24 (vinte e quatro) meses após seu término, o usuário e a organização que representa não poderão usar informações confidenciais, acesso privilegiado, fluxos internos, lógica, documentação ou conhecimento não público obtido na Plataforma para desenvolver, financiar, encomendar, comercializar ou auxiliar cópia ou solução substancialmente concorrente destinada ao mesmo público-alvo. Esta restrição não impede atividade profissional lícita, desenvolvimento comprovadamente independente, uso de conhecimento geral ou concorrência baseada em recursos públicos e próprios.

## 11. Proibição de repasse e aliciamento técnico
É proibido repassar o acesso ou demonstrar áreas restritas a desenvolvedores, concorrentes ou terceiros com objetivo de reprodução, benchmarking não autorizado ou apropriação de tecnologia. Também é proibido induzir colaboradores ou fornecedores a revelar código, arquitetura, credenciais, documentação ou segredos da Plataforma.

## 12. Multa, perdas e danos
A violação comprovada das obrigações de confidencialidade, não compartilhamento, propriedade intelectual, engenharia reversa, cópia, concorrência por uso indevido ou acesso não autorizado sujeitará o infrator à multa contratual de R$ 150.000,00 (cento e cinquenta mil reais) por evento grave, sem prejuízo da cessação imediata da conduta, tutela de urgência e indenização por perdas e danos comprovadamente excedentes, quando cabível e na medida permitida pela legislação. A aplicação observará a natureza da obrigação, a extensão do dano e os limites legais aplicáveis à cláusula penal.

## 13. Uso aceitável
É proibido utilizar a Plataforma para fraude, spam ilícito, discriminação, assédio, violação de direitos, tratamento ilegal de dados, invasão, testes de vulnerabilidade sem autorização, sobrecarga deliberada, malware ou qualquer atividade ilícita. O usuário responde pelo conteúdo inserido e pelas comunicações realizadas a partir dos dados cadastrados.

## 14. Natureza B2B, planos, cancelamentos e suspensão
A Plataforma é disponibilizada como serviço B2B, destinado ao uso profissional por agências, empresas e clientes empresariais, integrado às respectivas atividades econômicas e não direcionado a uso pessoal, familiar ou doméstico. Recursos podem depender de plano e quantidade de licenças definidos pelo Admin. A Agência escolhe quais clientes utilizarão as licenças disponíveis, sem ultrapassar a cota. Redução de plano pode bloquear novas ativações e exigir desativação de acessos excedentes.

Na relação comercial entre a Agência e os clientes que ela cadastra, contrata ou mantém, a Agência atua de forma independente e é responsável pelas próprias ofertas, preços, cobranças, recebimentos, suporte comercial, cancelamentos e devoluções ou reembolsos decorrentes de desistência ou encerramento. O Fornecedor não responde pela devolução de quantias que não tenha recebido. Valores cobrados e recebidos diretamente pelo Fornecedor serão tratados pelo próprio Fornecedor conforme a contratação e a legislação aplicável.

A caracterização contratual como B2B e a distribuição de responsabilidades não afastam direitos ou deveres legais obrigatórios que venham a ser reconhecidos no caso concreto. O acesso poderá ser suspenso por inadimplência, risco de segurança, violação destes Termos, ordem legal ou uso que prejudique terceiros ou a Plataforma.

## 15. Disponibilidade, resultados e limitações
A Plataforma é ferramenta de apoio e não garante vendas, faturamento, retorno de campanhas ou resultado comercial específico. Métricas dependem da qualidade e atualização dos dados inseridos. Manutenções, falhas de internet e indisponibilidades de infraestrutura podem ocorrer. Nenhuma cláusula exclui responsabilidade que não possa ser afastada por lei.

## 16. Assinatura eletrônica e evidências
As partes reconhecem como válida a assinatura eletrônica realizada na Plataforma por desenho com mouse, dedo ou caneta, vinculada à sessão autenticada, versão do documento, data e hora do servidor, identificador da conta, hashes de integridade e evidências técnicas disponíveis. O usuário concorda com o armazenamento dessas evidências e reconhece que elas poderão ser apresentadas para comprovar autoria, integridade, aceite e exercício regular de direitos.

## 17. Alterações e novo aceite
Os Termos podem ser atualizados para refletir mudanças legais, técnicas ou comerciais. Alterações materiais gerarão nova versão e poderão exigir novo aceite antes da continuidade do uso. A versão aceita permanece vinculada à respectiva evidência.

## 18. Rescisão e sobrevivência
O usuário pode deixar de utilizar a Plataforma, observadas obrigações contratuais e financeiras existentes. Permanecem após o término as cláusulas de confidencialidade, propriedade intelectual, restrições contra cópia e uso indevido, proteção de dados, retenção de evidências, responsabilidade e solução de controvérsias.

## 19. Legislação e solução de controvérsias
Aplicam-se as leis da República Federativa do Brasil. As partes buscarão solução de boa-fé antes de medida judicial. Fica eleito o foro do domicílio do Fornecedor acima identificado, salvo competência legal obrigatória, especialmente em relações de consumo.

## 20. Feedback, sugestões e melhorias
Ao enviar voluntariamente sugestão, ideia, correção, melhoria, feedback ou proposta relacionada à Plataforma, o usuário autoriza o Fornecedor, na máxima extensão permitida pela lei, a usar, avaliar, adaptar, desenvolver, incorporar, reproduzir, licenciar e explorar esse conteúdo livremente, sem obrigação de remuneração, reconhecimento, licença adicional ou atribuição ao usuário. Essa autorização é gratuita, mundial, por prazo indeterminado, não exclusiva, transferível e sublicenciável, e não alcança dados pessoais, informações confidenciais do usuário nem materiais preexistentes de terceiros além do necessário à finalidade autorizada.

## 21. Inteligência artificial, banco de dados, UX/UI e terceiros
Integram a propriedade intelectual e os ativos tecnológicos da Plataforma, conforme sua natureza e titularidade, os modelos e recursos de inteligência artificial, prompts, instruções de sistema, configurações, embeddings, agentes, fluxos de decisão, parâmetros, avaliações, automações, métricas e demais tecnologias utilizadas ou desenvolvidas, ainda que operem com serviços de terceiros.

Também são protegidos a estrutura, modelagem, organização, relacionamentos, índices, arquitetura, consultas e demais elementos técnicos do banco de dados, bem como a experiência do usuário (UX), identidade visual, interface (UI), navegação, disposição funcional, hierarquia de informações, fluxos operacionais e elementos de interação da Plataforma.

A Plataforma poderá utilizar bibliotecas, componentes, APIs, modelos, serviços e softwares licenciados por terceiros. Os respectivos direitos permanecem com seus titulares, e estes Termos não concedem ao usuário direitos além daqueles necessários ao uso regular da Plataforma.

## 22. APIs, automações, benchmarking e captura de interface
Sem autorização expressa do Fornecedor, é proibido utilizar APIs, integrações, automações, robôs, scripts, crawlers, técnicas de scraping ou outros mecanismos destinados à coleta massiva de informações, reprodução, extração, contorno de controles, engenharia reversa ou replicação total ou parcial da Plataforma, ressalvadas hipóteses legais que não possam ser afastadas.

O usuário não poderá utilizar o acesso para realizar testes comparativos, benchmarking técnico ou comercial, medição sistemática ou análise destinada ao desenvolvimento, treinamento, validação ou promoção de produto concorrente com base em elementos não públicos da Plataforma.

É vedada a gravação ou captura sistemática de telas, documentação técnica, mapeamento de fluxos ou reprodução da interface quando destinada à engenharia reversa, cópia ou desenvolvimento de solução concorrente. Permanecem permitidas capturas pontuais necessárias ao uso interno autorizado, suporte, treinamento da própria equipe ou exercício regular de direitos.

## 23. Segredos comerciais, auditoria e preservação de evidências
Consideram-se Segredos Comerciais, entre outros elementos não públicos, algoritmos, código, arquitetura, fluxos internos, modelos de dados, documentação, integrações, automações, métricas, estratégias, métodos operacionais, processos de desenvolvimento, configurações técnicas, credenciais, mecanismos de segurança e demais informações confidenciais relacionadas à Plataforma.

Havendo necessidade de segurança, prevenção a fraude, suporte, auditoria, investigação de incidente ou apuração de possível violação destes Termos, o Fornecedor poderá registrar e preservar logs, eventos, identificadores, trilhas técnicas e evidências pertinentes, observando finalidade, necessidade, acesso restrito, prazos aplicáveis e a legislação de proteção de dados.

## 24. Força maior e evolução da Plataforma
Na medida permitida pela lei, o Fornecedor não responderá por atraso ou indisponibilidade comprovadamente decorrente de caso fortuito ou força maior, falhas externas de energia, telecomunicações ou internet, indisponibilidade de provedores e serviços em nuvem, ataques generalizados, eventos naturais, conflitos, greves, atos de autoridade ou outros eventos inevitáveis fora de seu controle razoável. Essa previsão não exclui deveres legais obrigatórios nem a adoção de medidas razoáveis para reduzir impactos e restabelecer o serviço.

O Fornecedor poderá alterar, adicionar, remover, reorganizar ou substituir funcionalidades para evolução técnica, segurança, desempenho, conformidade legal ou melhoria da Plataforma, preservados os direitos dos usuários, a boa-fé e as obrigações legais e contratuais aplicáveis. Mudanças materiais poderão ser comunicadas e exigir novo aceite.

## 25. Interpretação restrita da não concorrência
A cláusula 10 não estabelece exclusividade, reserva de mercado ou proibição geral de trabalhar, empreender, prestar serviços ou desenvolver produto concorrente. Sua finalidade exclusiva é impedir o aproveitamento comprovado de Segredos Comerciais, acesso privilegiado, material confidencial e conhecimento não público obtido por meio da Plataforma para copiar ou reproduzir elemento substancial protegido.

O prazo de 24 (vinte e quatro) meses aplica-se somente a essa obrigação específica de não utilização indevida, sem limitar obrigações de confidencialidade, propriedade intelectual e proteção de segredos que, por sua natureza ou por lei, devam subsistir por período distinto. Permanecem permitidos desenvolvimento comprovadamente independente, conhecimento geral, informações públicas, experiência profissional legítima e concorrência baseada em recursos próprios e lícitos.

## 26. Declarações finais
Ao marcar as confirmações e assinar, o usuário declara que: leu integralmente estes Termos; recebeu oportunidade de esclarecer dúvidas; possui autorização para representar a organização; fornecerá dados verdadeiros; manterá credenciais seguras; respeitará a LGPD e os direitos dos titulares; não compartilhará o acesso; não copiará nem auxiliará cópia da Plataforma; e aceita a política de retenção e exportação descrita acima.
  $terms$,
  encode(digest(convert_to($terms$
## 1. Partes, finalidade e aceite
Estes Termos regulam o acesso à plataforma de Controle de Leads e Prospecções (“Plataforma”) pelo usuário, pela empresa cliente e, quando aplicável, pela agência responsável. O fornecedor e licenciante da Plataforma é JOAO MARCOS DIAS PAINA JUNIOR, pessoa física inscrita no CPF sob o nº 532.222.238-31, telefone (19) 99637-0701 e e-mail muitofacil18@gmail.com (“Fornecedor”). Ao assinar eletronicamente, o usuário confirma que leu, compreendeu e aceita integralmente estes Termos e que possui capacidade e poderes para vincular a conta e a organização que representa.

## 2. Objeto e licença limitada
A Plataforma disponibiliza recursos de cadastro, organização, análise, acompanhamento e exportação de leads e prospecções. É concedida licença temporária, revogável, não exclusiva, intransferível e limitada ao uso interno da organização autorizada, durante a vigência do plano contratado. Nenhum direito sobre código-fonte, arquitetura, identidade visual, fluxos, métodos, modelos de dados, documentação, lógica de negócio ou tecnologia é transferido ao usuário.

## 3. Contas, credenciais e usuários autorizados
Cada acesso é pessoal e deve ser utilizado exclusivamente pela pessoa ou equipe expressamente autorizada. É proibido vender, ceder, sublicenciar, emprestar, compartilhar credenciais ou permitir acesso a terceiros sem autorização formal. O titular da conta responde por manter senha e dispositivos seguros, encerrar sessões em equipamentos compartilhados e informar imediatamente qualquer suspeita de uso indevido.

## 4. Hierarquia de acesso e confidencialidade
Os dados de cada cliente permanecem segregados por conta. Podem acessá-los: o próprio cliente autorizado; a agência vinculada àquele cliente, para execução dos serviços contratados; e o Admin, para administração, suporte, segurança, auditoria e operação da Plataforma. Usuários não podem acessar contas fora de seu escopo. Todos os envolvidos devem preservar confidencialidade e utilizar os dados apenas para as finalidades profissionais autorizadas.

## 5. Proteção de dados pessoais e LGPD
As partes comprometem-se a observar a Lei nº 13.709/2018 (LGPD), incluindo finalidade, adequação, necessidade, transparência, segurança, prevenção e prestação de contas. Em regra, o cliente e/ou a agência que decide quais dados inserir e para quais finalidades atua como controlador; o fornecedor da Plataforma atua como operador nos limites das instruções e da prestação tecnológica, sem prejuízo das responsabilidades específicas que a lei atribuir a cada parte.

- O usuário deve possuir base legal válida para cadastrar e tratar dados de leads, clientes, funcionários e demais titulares.
- Devem ser inseridos apenas dados necessários à finalidade comercial legítima e informada.
- Solicitações de titulares devem ser encaminhadas imediatamente ao responsável pela conta e tratadas conforme a LGPD.
- É proibido inserir dados obtidos de forma ilícita, discriminatória, enganosa ou incompatível com a finalidade declarada.
- A assinatura desenhada, o identificador da conta e as evidências do aceite são tratados para autenticação, execução contratual, prevenção a fraude e exercício regular de direitos.

## 6. Compartilhamento e infraestrutura Supabase
Os dados não são vendidos, alugados nem compartilhados para publicidade de terceiros. O acesso funcional fica restrito ao usuário autorizado, ao Admin e à agência vinculada, conforme a hierarquia da conta. Poderá ocorrer tratamento técnico por fornecedores essenciais de infraestrutura, especialmente o Supabase, utilizado para banco de dados, autenticação, disponibilidade e recursos de segurança, além de divulgação quando exigida por lei, ordem judicial ou autoridade competente.

A segurança opera em modelo de responsabilidade compartilhada. A Plataforma depende da disponibilidade e da arquitetura de segurança do Supabase, do qual o fornecedor é cliente, e também das configurações, controles de acesso e código mantidos pelo fornecedor da Plataforma. Essa dependência não elimina obrigações legais inderrogáveis, mas eventos exclusivamente causados pela infraestrutura de terceiros serão apurados conforme a participação e a responsabilidade de cada agente.

## 7. Segurança e incidentes
São adotadas medidas técnicas e administrativas compatíveis com a natureza do serviço, incluindo segregação lógica, autenticação, restrição de acesso e trilha de evidências. Nenhum sistema é absolutamente imune a falhas. O usuário deve colaborar com investigações, preservar evidências e comunicar incidentes. Incidentes com risco ou dano relevante serão tratados e comunicados nos termos aplicáveis da LGPD.

## 8. Retenção, exportação e exclusão
Os registros operacionais de Prospecções são mantidos por uma janela móvel máxima de 2 (dois) anos contada da criação de cada registro. Dados mais antigos são eliminados automaticamente para dar lugar aos registros novos, salvo obrigação legal, ordem de preservação ou necessidade legítima de exercício de direitos. O cliente deve realizar exportações periódicas quando precisar manter histórico próprio por prazo superior.

Se o acesso ao módulo Prospecções for desativado, a operação e a visualização analítica ficam bloqueadas, mas a conta poderá exportar os registros ainda existentes durante a janela de retenção. A reativação não recupera dados que já tenham sido eliminados pela política de dois anos. Evidências de aceite, auditoria, segurança e documentos contratuais podem ser conservados por prazo distinto quando necessários ao cumprimento de obrigação legal ou ao exercício regular de direitos.

## 9. Propriedade intelectual e uso restrito
Todos os direitos sobre a Plataforma, incluindo software, interfaces, design, fluxos, automações, lógica de registro, organização, facilitação de uso, relatórios, documentação, marcas, segredos de negócio e melhorias pertencem ao fornecedor ou a seus licenciantes. O usuário não poderá copiar, reproduzir, adaptar, traduzir, desmontar, descompilar, realizar engenharia reversa, extrair código, contornar controles, criar obra derivada ou explorar elemento substancial da Plataforma, salvo autorização escrita ou hipótese legal que não possa ser afastada contratualmente.

## 10. Não concorrência por uso indevido e não aproveitamento parasitário
Durante o acesso e por 24 (vinte e quatro) meses após seu término, o usuário e a organização que representa não poderão usar informações confidenciais, acesso privilegiado, fluxos internos, lógica, documentação ou conhecimento não público obtido na Plataforma para desenvolver, financiar, encomendar, comercializar ou auxiliar cópia ou solução substancialmente concorrente destinada ao mesmo público-alvo. Esta restrição não impede atividade profissional lícita, desenvolvimento comprovadamente independente, uso de conhecimento geral ou concorrência baseada em recursos públicos e próprios.

## 11. Proibição de repasse e aliciamento técnico
É proibido repassar o acesso ou demonstrar áreas restritas a desenvolvedores, concorrentes ou terceiros com objetivo de reprodução, benchmarking não autorizado ou apropriação de tecnologia. Também é proibido induzir colaboradores ou fornecedores a revelar código, arquitetura, credenciais, documentação ou segredos da Plataforma.

## 12. Multa, perdas e danos
A violação comprovada das obrigações de confidencialidade, não compartilhamento, propriedade intelectual, engenharia reversa, cópia, concorrência por uso indevido ou acesso não autorizado sujeitará o infrator à multa contratual de R$ 150.000,00 (cento e cinquenta mil reais) por evento grave, sem prejuízo da cessação imediata da conduta, tutela de urgência e indenização por perdas e danos comprovadamente excedentes, quando cabível e na medida permitida pela legislação. A aplicação observará a natureza da obrigação, a extensão do dano e os limites legais aplicáveis à cláusula penal.

## 13. Uso aceitável
É proibido utilizar a Plataforma para fraude, spam ilícito, discriminação, assédio, violação de direitos, tratamento ilegal de dados, invasão, testes de vulnerabilidade sem autorização, sobrecarga deliberada, malware ou qualquer atividade ilícita. O usuário responde pelo conteúdo inserido e pelas comunicações realizadas a partir dos dados cadastrados.

## 14. Natureza B2B, planos, cancelamentos e suspensão
A Plataforma é disponibilizada como serviço B2B, destinado ao uso profissional por agências, empresas e clientes empresariais, integrado às respectivas atividades econômicas e não direcionado a uso pessoal, familiar ou doméstico. Recursos podem depender de plano e quantidade de licenças definidos pelo Admin. A Agência escolhe quais clientes utilizarão as licenças disponíveis, sem ultrapassar a cota. Redução de plano pode bloquear novas ativações e exigir desativação de acessos excedentes.

Na relação comercial entre a Agência e os clientes que ela cadastra, contrata ou mantém, a Agência atua de forma independente e é responsável pelas próprias ofertas, preços, cobranças, recebimentos, suporte comercial, cancelamentos e devoluções ou reembolsos decorrentes de desistência ou encerramento. O Fornecedor não responde pela devolução de quantias que não tenha recebido. Valores cobrados e recebidos diretamente pelo Fornecedor serão tratados pelo próprio Fornecedor conforme a contratação e a legislação aplicável.

A caracterização contratual como B2B e a distribuição de responsabilidades não afastam direitos ou deveres legais obrigatórios que venham a ser reconhecidos no caso concreto. O acesso poderá ser suspenso por inadimplência, risco de segurança, violação destes Termos, ordem legal ou uso que prejudique terceiros ou a Plataforma.

## 15. Disponibilidade, resultados e limitações
A Plataforma é ferramenta de apoio e não garante vendas, faturamento, retorno de campanhas ou resultado comercial específico. Métricas dependem da qualidade e atualização dos dados inseridos. Manutenções, falhas de internet e indisponibilidades de infraestrutura podem ocorrer. Nenhuma cláusula exclui responsabilidade que não possa ser afastada por lei.

## 16. Assinatura eletrônica e evidências
As partes reconhecem como válida a assinatura eletrônica realizada na Plataforma por desenho com mouse, dedo ou caneta, vinculada à sessão autenticada, versão do documento, data e hora do servidor, identificador da conta, hashes de integridade e evidências técnicas disponíveis. O usuário concorda com o armazenamento dessas evidências e reconhece que elas poderão ser apresentadas para comprovar autoria, integridade, aceite e exercício regular de direitos.

## 17. Alterações e novo aceite
Os Termos podem ser atualizados para refletir mudanças legais, técnicas ou comerciais. Alterações materiais gerarão nova versão e poderão exigir novo aceite antes da continuidade do uso. A versão aceita permanece vinculada à respectiva evidência.

## 18. Rescisão e sobrevivência
O usuário pode deixar de utilizar a Plataforma, observadas obrigações contratuais e financeiras existentes. Permanecem após o término as cláusulas de confidencialidade, propriedade intelectual, restrições contra cópia e uso indevido, proteção de dados, retenção de evidências, responsabilidade e solução de controvérsias.

## 19. Legislação e solução de controvérsias
Aplicam-se as leis da República Federativa do Brasil. As partes buscarão solução de boa-fé antes de medida judicial. Fica eleito o foro do domicílio do Fornecedor acima identificado, salvo competência legal obrigatória, especialmente em relações de consumo.

## 20. Feedback, sugestões e melhorias
Ao enviar voluntariamente sugestão, ideia, correção, melhoria, feedback ou proposta relacionada à Plataforma, o usuário autoriza o Fornecedor, na máxima extensão permitida pela lei, a usar, avaliar, adaptar, desenvolver, incorporar, reproduzir, licenciar e explorar esse conteúdo livremente, sem obrigação de remuneração, reconhecimento, licença adicional ou atribuição ao usuário. Essa autorização é gratuita, mundial, por prazo indeterminado, não exclusiva, transferível e sublicenciável, e não alcança dados pessoais, informações confidenciais do usuário nem materiais preexistentes de terceiros além do necessário à finalidade autorizada.

## 21. Inteligência artificial, banco de dados, UX/UI e terceiros
Integram a propriedade intelectual e os ativos tecnológicos da Plataforma, conforme sua natureza e titularidade, os modelos e recursos de inteligência artificial, prompts, instruções de sistema, configurações, embeddings, agentes, fluxos de decisão, parâmetros, avaliações, automações, métricas e demais tecnologias utilizadas ou desenvolvidas, ainda que operem com serviços de terceiros.

Também são protegidos a estrutura, modelagem, organização, relacionamentos, índices, arquitetura, consultas e demais elementos técnicos do banco de dados, bem como a experiência do usuário (UX), identidade visual, interface (UI), navegação, disposição funcional, hierarquia de informações, fluxos operacionais e elementos de interação da Plataforma.

A Plataforma poderá utilizar bibliotecas, componentes, APIs, modelos, serviços e softwares licenciados por terceiros. Os respectivos direitos permanecem com seus titulares, e estes Termos não concedem ao usuário direitos além daqueles necessários ao uso regular da Plataforma.

## 22. APIs, automações, benchmarking e captura de interface
Sem autorização expressa do Fornecedor, é proibido utilizar APIs, integrações, automações, robôs, scripts, crawlers, técnicas de scraping ou outros mecanismos destinados à coleta massiva de informações, reprodução, extração, contorno de controles, engenharia reversa ou replicação total ou parcial da Plataforma, ressalvadas hipóteses legais que não possam ser afastadas.

O usuário não poderá utilizar o acesso para realizar testes comparativos, benchmarking técnico ou comercial, medição sistemática ou análise destinada ao desenvolvimento, treinamento, validação ou promoção de produto concorrente com base em elementos não públicos da Plataforma.

É vedada a gravação ou captura sistemática de telas, documentação técnica, mapeamento de fluxos ou reprodução da interface quando destinada à engenharia reversa, cópia ou desenvolvimento de solução concorrente. Permanecem permitidas capturas pontuais necessárias ao uso interno autorizado, suporte, treinamento da própria equipe ou exercício regular de direitos.

## 23. Segredos comerciais, auditoria e preservação de evidências
Consideram-se Segredos Comerciais, entre outros elementos não públicos, algoritmos, código, arquitetura, fluxos internos, modelos de dados, documentação, integrações, automações, métricas, estratégias, métodos operacionais, processos de desenvolvimento, configurações técnicas, credenciais, mecanismos de segurança e demais informações confidenciais relacionadas à Plataforma.

Havendo necessidade de segurança, prevenção a fraude, suporte, auditoria, investigação de incidente ou apuração de possível violação destes Termos, o Fornecedor poderá registrar e preservar logs, eventos, identificadores, trilhas técnicas e evidências pertinentes, observando finalidade, necessidade, acesso restrito, prazos aplicáveis e a legislação de proteção de dados.

## 24. Força maior e evolução da Plataforma
Na medida permitida pela lei, o Fornecedor não responderá por atraso ou indisponibilidade comprovadamente decorrente de caso fortuito ou força maior, falhas externas de energia, telecomunicações ou internet, indisponibilidade de provedores e serviços em nuvem, ataques generalizados, eventos naturais, conflitos, greves, atos de autoridade ou outros eventos inevitáveis fora de seu controle razoável. Essa previsão não exclui deveres legais obrigatórios nem a adoção de medidas razoáveis para reduzir impactos e restabelecer o serviço.

O Fornecedor poderá alterar, adicionar, remover, reorganizar ou substituir funcionalidades para evolução técnica, segurança, desempenho, conformidade legal ou melhoria da Plataforma, preservados os direitos dos usuários, a boa-fé e as obrigações legais e contratuais aplicáveis. Mudanças materiais poderão ser comunicadas e exigir novo aceite.

## 25. Interpretação restrita da não concorrência
A cláusula 10 não estabelece exclusividade, reserva de mercado ou proibição geral de trabalhar, empreender, prestar serviços ou desenvolver produto concorrente. Sua finalidade exclusiva é impedir o aproveitamento comprovado de Segredos Comerciais, acesso privilegiado, material confidencial e conhecimento não público obtido por meio da Plataforma para copiar ou reproduzir elemento substancial protegido.

O prazo de 24 (vinte e quatro) meses aplica-se somente a essa obrigação específica de não utilização indevida, sem limitar obrigações de confidencialidade, propriedade intelectual e proteção de segredos que, por sua natureza ou por lei, devam subsistir por período distinto. Permanecem permitidos desenvolvimento comprovadamente independente, conhecimento geral, informações públicas, experiência profissional legítima e concorrência baseada em recursos próprios e lícitos.

## 26. Declarações finais
Ao marcar as confirmações e assinar, o usuário declara que: leu integralmente estes Termos; recebeu oportunidade de esclarecer dúvidas; possui autorização para representar a organização; fornecerá dados verdadeiros; manterá credenciais seguras; respeitará a LGPD e os direitos dos titulares; não compartilhará o acesso; não copiará nem auxiliará cópia da Plataforma; e aceita a política de retenção e exportação descrita acima.
  $terms$, 'UTF8'), 'sha256'), 'hex'),
  now(),
  true
)
on conflict (version) do update set
  title = excluded.title,
  content = excluded.content,
  content_hash = excluded.content_hash,
  effective_at = excluded.effective_at,
  is_active = true;

create or replace function app_private.session_user_unchecked(p_session_token text)
returns table (
  user_id uuid,
  admin_user_id uuid,
  user_role public.app_user_role,
  user_store_id uuid
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_token_hash text;
begin
  if coalesce(p_session_token, '') = '' then
    raise exception 'Sessao obrigatoria.' using errcode = '28000';
  end if;

  v_token_hash := encode(digest(p_session_token, 'sha256'), 'hex');

  return query
  select u.id, coalesce(u.admin_user_id, u.id), u.role, u.store_id
  from public.app_sessions s
  join public.app_users u on u.id = s.user_id
  left join public.stores st on st.id = u.store_id
  where s.token_hash = v_token_hash
    and s.revoked_at is null
    and s.expires_at > now()
    and u.is_active = true
    and (u.role in ('admin', 'technician') or (st.id is not null and st.is_active = true))
  limit 1;

  if not found then
    raise exception 'Sessao invalida ou expirada.' using errcode = '28000';
  end if;

  update public.app_sessions set last_seen_at = now() where token_hash = v_token_hash;
end;
$$;

create or replace function app_private.legal_terms_satisfied(p_user_id uuid, p_user_role public.app_user_role)
returns boolean
language sql
stable
security definer
set search_path = app_private, public, extensions
as $$
  select exists (
    select 1
    from public.legal_term_acceptances a
    join public.system_legal_terms t on t.id = a.terms_id and t.is_active = true
    where a.accepting_user_id = p_user_id
  );
$$;

create or replace function app_private.is_valid_cpf(p_cpf text)
returns boolean
language plpgsql
immutable
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_cpf text := regexp_replace(coalesce(p_cpf, ''), '[^0-9]', '', 'g');
  v_sum integer;
  v_digit integer;
  v_index integer;
begin
  if length(v_cpf) <> 11 or v_cpf ~ '^([0-9])\1{10}$' then
    return false;
  end if;

  v_sum := 0;
  for v_index in 1..9 loop
    v_sum := v_sum + substr(v_cpf, v_index, 1)::integer * (11 - v_index);
  end loop;
  v_digit := 11 - (v_sum % 11);
  if v_digit >= 10 then v_digit := 0; end if;
  if v_digit <> substr(v_cpf, 10, 1)::integer then return false; end if;

  v_sum := 0;
  for v_index in 1..10 loop
    v_sum := v_sum + substr(v_cpf, v_index, 1)::integer * (12 - v_index);
  end loop;
  v_digit := 11 - (v_sum % 11);
  if v_digit >= 10 then v_digit := 0; end if;
  return v_digit = substr(v_cpf, 11, 1)::integer;
end;
$$;

create or replace function app_private.session_user(p_session_token text)
returns table (
  user_id uuid,
  admin_user_id uuid,
  user_role public.app_user_role,
  user_store_id uuid
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user_unchecked(p_session_token);

  if coalesce(current_setting('app.legal_gate_bypass', true), '') <> 'on'
     and not app_private.legal_terms_satisfied(v_session.user_id, v_session.user_role) then
    raise exception 'TERMOS_DE_USO_PENDENTES: leia e assine a versao vigente para continuar.';
  end if;

  return query select
    v_session.user_id::uuid,
    v_session.admin_user_id::uuid,
    v_session.user_role::public.app_user_role,
    v_session.user_store_id::uuid;
end;
$$;

-- Permite reduzir a franquia mesmo quando existem mais acessos ativos que o
-- novo limite. Nessa situação, a agência continua podendo desativar qualquer
-- cliente, enquanto o trigger de cota impede somente novas ativações.
create or replace function app_private.rpc_set_technician_prospection_limit(
  p_session_token text,
  p_technician_id uuid,
  p_limit integer
)
returns boolean
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_store_limit integer;
begin
  select * into v_session from app_private.session_user(p_session_token);

  if v_session.user_role::text <> 'admin' then
    raise exception 'Apenas o Admin pode alterar o limite de Prospeccoes.';
  end if;
  if coalesce(p_limit, -1) not between 0 and 9999 then
    raise exception 'Informe um limite de Prospeccoes entre 0 e 9999.';
  end if;

  select u.store_limit into v_store_limit
  from public.app_users u
  where u.id = p_technician_id
    and u.admin_user_id = v_session.admin_user_id
    and u.role::text = 'technician'
    and u.is_active = true
  for update;

  if not found then raise exception 'Agencia nao encontrada.'; end if;
  if p_limit > v_store_limit then
    raise exception 'O limite de Prospeccoes nao pode superar o limite total de % clientes.', v_store_limit;
  end if;

  update public.app_users
  set prospection_store_limit = p_limit
  where id = p_technician_id;

  return true;
end;
$$;

-- O perfil precisa ser restaurado antes da abertura do modal obrigatório.
create or replace function app_private.profile_result(p_session_token text)
returns table (
  user_id uuid,
  admin_id uuid,
  nick text,
  full_name text,
  role public.app_user_role,
  store_id uuid,
  store_name text
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  perform set_config('app.legal_gate_bypass', 'on', true);
  select * into v_session from app_private.session_user(p_session_token);

  return query
  select u.id, v_session.admin_user_id, u.nick_key, u.full_name, u.role, u.store_id, st.name
  from public.app_users u
  left join public.stores st on st.id = u.store_id
  where u.id = v_session.user_id;
end;
$$;

create or replace function app_private.rpc_get_required_legal_terms(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_terms record;
  v_acceptance record;
begin
  select * into v_session from app_private.session_user_unchecked(p_session_token);
  select * into v_terms from public.system_legal_terms where is_active = true limit 1;

  if not found then
    raise exception 'TERMOS_DE_USO_INDISPONIVEIS: nenhum documento ativo foi configurado.';
  end if;

  select a.id, a.accepted_at, a.evidence_hash
  into v_acceptance
  from public.legal_term_acceptances a
  where a.terms_id = v_terms.id and a.accepting_user_id = v_session.user_id
  limit 1;

  return jsonb_build_object(
    'required', v_acceptance.id is null,
    'terms', jsonb_build_object(
      'id', v_terms.id,
      'version', v_terms.version,
      'title', v_terms.title,
      'content', v_terms.content,
      'content_hash', v_terms.content_hash,
      'effective_at', v_terms.effective_at
    ),
    'acceptance', case when v_acceptance.id is null then null else jsonb_build_object(
      'id', v_acceptance.id,
      'accepted_at', v_acceptance.accepted_at,
      'evidence_hash', v_acceptance.evidence_hash
    ) end
  );
end;
$$;

create or replace function app_private.rpc_accept_legal_terms(
  p_session_token text,
  p_signer_name text,
  p_signer_role text,
  p_signer_cpf text,
  p_signature_data_url text,
  p_user_agent text default null,
  p_client_timezone text default null,
  p_client_timestamp timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_terms record;
  v_user record;
  v_cpf text;
  v_cpf_hash text;
  v_signature_hash text;
  v_headers jsonb := '{}'::jsonb;
  v_ip text;
  v_user_agent text;
  v_accepted_at timestamptz := clock_timestamp();
  v_acceptance_id uuid;
begin
  select * into v_session from app_private.session_user_unchecked(p_session_token);

  select * into v_terms from public.system_legal_terms where is_active = true limit 1;
  if not found then raise exception 'Nenhum Termo de Uso ativo foi encontrado.'; end if;

  select a.id into v_acceptance_id
  from public.legal_term_acceptances a
  where a.terms_id = v_terms.id and a.accepting_user_id = v_session.user_id;
  if found then return v_acceptance_id; end if;

  if length(btrim(coalesce(p_signer_name, ''))) < 3 then raise exception 'Informe o nome completo do responsável.'; end if;
  if length(btrim(coalesce(p_signer_role, ''))) < 2 then raise exception 'Informe o cargo ou função do responsável.'; end if;

  v_cpf := regexp_replace(coalesce(p_signer_cpf, ''), '[^0-9]', '', 'g');
  if not app_private.is_valid_cpf(v_cpf) then raise exception 'Informe um CPF válido.'; end if;

  if coalesce(p_signature_data_url, '') not like 'data:image/png;base64,%'
     or length(p_signature_data_url) < 300
     or length(p_signature_data_url) > 600000 then
    raise exception 'Faça a assinatura no campo indicado.';
  end if;

  begin
    v_headers := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  exception when others then
    v_headers := '{}'::jsonb;
  end;

  v_ip := coalesce(
    nullif(v_headers->>'cf-connecting-ip', ''),
    nullif(split_part(coalesce(v_headers->>'x-forwarded-for', ''), ',', 1), ''),
    nullif(v_headers->>'x-real-ip', ''),
    'não disponível'
  );
  v_user_agent := left(coalesce(nullif(p_user_agent, ''), nullif(v_headers->>'user-agent', ''), 'não disponível'), 1000);
  v_cpf_hash := encode(digest(v_cpf, 'sha256'), 'hex');
  v_signature_hash := encode(digest(convert_to(p_signature_data_url, 'UTF8'), 'sha256'), 'hex');

  select
    u.full_name,
    u.nick_key,
    coalesce(st.name, u.full_name) as account_name,
    case when u.role::text = 'technician' then u.full_name else tech.full_name end as agency_name,
    st.name as store_name
  into v_user
  from public.app_users u
  left join public.stores st on st.id = u.store_id
  left join public.app_users tech on tech.id = st.technician_user_id
  where u.id = v_session.user_id;

  insert into public.legal_term_acceptances (
    terms_id, terms_version, terms_title, terms_snapshot, terms_hash,
    admin_user_id, accepting_user_id, account_role, account_name_snapshot,
    agency_name_snapshot, store_name_snapshot, signer_name, signer_role,
    signer_cpf_hash, signer_cpf_last4, signature_data_url, signature_hash,
    confirmations, ip_address, user_agent, client_timezone, client_timestamp,
    accepted_at, evidence_hash
  ) values (
    v_terms.id, v_terms.version, v_terms.title, v_terms.content, v_terms.content_hash,
    v_session.admin_user_id, v_session.user_id, v_session.user_role, v_user.account_name,
    v_user.agency_name, v_user.store_name, btrim(p_signer_name), btrim(p_signer_role),
    v_cpf_hash, right(v_cpf, 4), p_signature_data_url, v_signature_hash,
    jsonb_build_array(
      'Li e aceito integralmente os Termos de Uso e Privacidade.',
      'Declaro possuir autorização para representar esta conta e organização.',
      'Reconheço a assinatura eletrônica, a política de dados e a retenção de dois anos.'
    ),
    v_ip, v_user_agent, left(coalesce(p_client_timezone, ''), 120), p_client_timestamp,
    v_accepted_at,
    encode(digest(concat_ws('|', v_terms.content_hash, v_session.user_id::text, v_cpf_hash, v_signature_hash, v_ip, v_user_agent, v_accepted_at::text), 'sha256'), 'hex')
  ) returning id into v_acceptance_id;

  return v_acceptance_id;
end;
$$;

create or replace function app_private.rpc_list_legal_acceptances(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text <> 'admin' then raise exception 'Apenas o Admin pode consultar os termos assinados.'; end if;

  with active_terms as (
    select id, version from public.system_legal_terms where is_active = true limit 1
  ), account_rows as (
    select
      u.id as user_id,
      u.role::text as account_role,
      coalesce(st.name, u.full_name) as account_name,
      case when u.role::text = 'technician' then u.full_name when u.role::text = 'store' then tech.full_name else null end as agency_name,
      st.name as store_name,
      u.nick_key as login,
      u.created_at as account_created_at,
      la.id as acceptance_id,
      la.terms_id,
      la.terms_version,
      la.signer_name,
      la.signer_role,
      la.signer_cpf_last4,
      la.accepted_at,
      la.evidence_hash,
      (la.id is not null and la.terms_id = at.id) as accepted_current,
      (la.id is not null and la.terms_id <> at.id) as outdated
    from public.app_users u
    cross join active_terms at
    left join public.stores st on st.id = u.store_id
    left join public.app_users tech on tech.id = st.technician_user_id
    left join lateral (
      select a.* from public.legal_term_acceptances a
      where a.accepting_user_id = u.id
      order by a.accepted_at desc
      limit 1
    ) la on true
    where (u.id = v_session.admin_user_id or u.admin_user_id = v_session.admin_user_id)
      and u.role::text in ('admin', 'technician', 'store')
      and u.is_active = true
  )
  select jsonb_build_object(
    'active_version', coalesce((select version from active_terms), ''),
    'total', count(*),
    'accepted', count(*) filter (where accepted_current),
    'pending', count(*) filter (where not accepted_current),
    'accounts', coalesce(jsonb_agg(jsonb_build_object(
      'user_id', user_id,
      'account_role', account_role,
      'account_name', account_name,
      'agency_name', agency_name,
      'store_name', store_name,
      'login', login,
      'account_created_at', account_created_at,
      'acceptance_id', acceptance_id,
      'terms_version', terms_version,
      'signer_name', signer_name,
      'signer_role', signer_role,
      'signer_cpf_last4', signer_cpf_last4,
      'accepted_at', accepted_at,
      'evidence_hash', evidence_hash,
      'status', case when accepted_current then 'accepted' when outdated then 'outdated' else 'pending' end
    ) order by accepted_current, account_role, account_name), '[]'::jsonb)
  ) into v_result
  from account_rows;

  return coalesce(v_result, jsonb_build_object('active_version', '', 'total', 0, 'accepted', 0, 'pending', 0, 'accounts', '[]'::jsonb));
end;
$$;

create or replace function app_private.rpc_get_legal_acceptance_document(p_session_token text, p_acceptance_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_result jsonb;
begin
  select * into v_session from app_private.session_user(p_session_token);
  if v_session.user_role::text <> 'admin' then raise exception 'Apenas o Admin pode abrir este documento.'; end if;

  select jsonb_build_object(
    'id', a.id,
    'terms_version', a.terms_version,
    'terms_title', a.terms_title,
    'terms_snapshot', a.terms_snapshot,
    'terms_hash', a.terms_hash,
    'account_role', a.account_role,
    'account_name', a.account_name_snapshot,
    'agency_name', a.agency_name_snapshot,
    'store_name', a.store_name_snapshot,
    'signer_name', a.signer_name,
    'signer_role', a.signer_role,
    'signer_cpf_last4', a.signer_cpf_last4,
    'signature_data_url', a.signature_data_url,
    'signature_hash', a.signature_hash,
    'confirmations', a.confirmations,
    'ip_address', a.ip_address,
    'user_agent', a.user_agent,
    'client_timezone', a.client_timezone,
    'client_timestamp', a.client_timestamp,
    'accepted_at', a.accepted_at,
    'evidence_hash', a.evidence_hash
  ) into v_result
  from public.legal_term_acceptances a
  where a.id = p_acceptance_id and a.admin_user_id = v_session.admin_user_id;

  if v_result is null then raise exception 'Documento assinado não encontrado.'; end if;
  return v_result;
end;
$$;

create or replace function public.lc_get_required_legal_terms(p_session_token text)
returns jsonb language sql security invoker
as $$ select app_private.rpc_get_required_legal_terms(p_session_token); $$;

create or replace function public.lc_accept_legal_terms(
  p_session_token text,
  p_signer_name text,
  p_signer_role text,
  p_signer_cpf text,
  p_signature_data_url text,
  p_user_agent text default null,
  p_client_timezone text default null,
  p_client_timestamp timestamptz default null
)
returns uuid language sql security invoker
as $$ select app_private.rpc_accept_legal_terms(p_session_token, p_signer_name, p_signer_role, p_signer_cpf, p_signature_data_url, p_user_agent, p_client_timezone, p_client_timestamp); $$;

create or replace function public.lc_list_legal_acceptances(p_session_token text)
returns jsonb language sql security invoker
as $$ select app_private.rpc_list_legal_acceptances(p_session_token); $$;

create or replace function public.lc_get_legal_acceptance_document(p_session_token text, p_acceptance_id uuid)
returns jsonb language sql security invoker
as $$ select app_private.rpc_get_legal_acceptance_document(p_session_token, p_acceptance_id); $$;

-- --------------------------------------------------------------------------
-- EXPORTAÇÃO DE PROSPECÇÕES MESMO APÓS O DOWNGRADE
-- --------------------------------------------------------------------------

create or replace function app_private.rpc_export_prospections(p_session_token text, p_store_id uuid default null)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  technician_id uuid,
  name text,
  phone text,
  cpf text,
  notes text,
  probability text,
  tags text[],
  professional_id uuid,
  professional_name text,
  returned_at timestamptz,
  purchased_at timestamptz,
  purchase_amount numeric,
  purchase_order text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
  v_requested_store uuid;
begin
  select * into v_session from app_private.session_user(p_session_token);
  perform app_private.purge_expired_prospections();
  v_requested_store := case when v_session.user_role::text = 'store' then v_session.user_store_id else p_store_id end;

  return query
  select
    pr.id, pr.store_id, st.name, st.technician_user_id, pr.name, pr.phone, pr.cpf,
    pr.notes, pr.probability, pr.tags, pr.professional_id,
    coalesce(pp.name, pr.professional_name_snapshot), pr.returned_at, pr.purchased_at,
    pr.purchase_amount, pr.purchase_order, pr.created_at, pr.updated_at
  from public.prospections pr
  join public.stores st on st.id = pr.store_id and st.admin_user_id = pr.admin_user_id
  left join public.prospection_professionals pp on pp.id = pr.professional_id
  where pr.admin_user_id = v_session.admin_user_id
    and st.is_active = true
    and pr.created_at >= now() - interval '2 years'
    and (v_requested_store is null or pr.store_id = v_requested_store)
    and (
      v_session.user_role::text = 'admin'
      or (v_session.user_role::text = 'technician' and st.technician_user_id = v_session.user_id)
      or (v_session.user_role::text = 'store' and st.id = v_session.user_store_id)
    )
  order by pr.created_at desc;
end;
$$;

create or replace function public.lc_export_prospections(p_session_token text, p_store_id uuid default null)
returns table (
  id uuid, store_id uuid, store_name text, technician_id uuid, name text,
  phone text, cpf text, notes text, probability text, tags text[],
  professional_id uuid, professional_name text, returned_at timestamptz,
  purchased_at timestamptz, purchase_amount numeric, purchase_order text,
  created_at timestamptz, updated_at timestamptz
)
language sql security invoker
as $$ select * from app_private.rpc_export_prospections(p_session_token, p_store_id); $$;

-- --------------------------------------------------------------------------
-- RETENÇÃO MÓVEL DE DOIS ANOS PARA REGISTROS DE PROSPECÇÕES
-- --------------------------------------------------------------------------

create index if not exists prospections_retention_created_idx
  on public.prospections (created_at);

create or replace function app_private.purge_expired_prospections()
returns integer
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_deleted integer;
begin
  delete from public.prospections
  where created_at < now() - interval '2 years';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

-- O filtro também é aplicado na leitura. Assim, mesmo sem pg_cron habilitado,
-- um registro vencido nunca volta para a interface; a própria consulta remove
-- fisicamente os vencidos antes de retornar a janela válida.
create or replace function app_private.rpc_list_prospections(p_session_token text)
returns table (
  id uuid,
  store_id uuid,
  store_name text,
  technician_id uuid,
  name text,
  phone text,
  cpf text,
  notes text,
  probability text,
  tags text[],
  professional_id uuid,
  professional_name text,
  returned_at timestamptz,
  purchased_at timestamptz,
  purchase_amount numeric,
  purchase_order text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
declare
  v_session record;
begin
  select * into v_session from app_private.session_user(p_session_token);
  perform app_private.purge_expired_prospections();

  return query
  select
    pr.id, pr.store_id, st.name, st.technician_user_id, pr.name, pr.phone, pr.cpf,
    pr.notes, pr.probability, pr.tags, pr.professional_id,
    coalesce(pp.name, pr.professional_name_snapshot), pr.returned_at, pr.purchased_at,
    pr.purchase_amount, pr.purchase_order, pr.created_at, pr.updated_at
  from public.prospections pr
  join public.stores st on st.id = pr.store_id and st.admin_user_id = pr.admin_user_id
  left join public.prospection_professionals pp on pp.id = pr.professional_id
  where pr.admin_user_id = v_session.admin_user_id
    and pr.created_at >= now() - interval '2 years'
    and app_private.prospection_store_allowed(
      v_session.admin_user_id,
      v_session.user_id,
      v_session.user_role,
      v_session.user_store_id,
      pr.store_id,
      false
    )
  order by pr.created_at desc;
end;
$$;

create or replace function app_private.trigger_purge_expired_prospections()
returns trigger
language plpgsql
security definer
set search_path = app_private, public, extensions
as $$
begin
  perform app_private.purge_expired_prospections();
  return null;
end;
$$;

drop trigger if exists prospections_enforce_two_year_retention on public.prospections;
create trigger prospections_enforce_two_year_retention
after insert on public.prospections
for each statement execute function app_private.trigger_purge_expired_prospections();

-- Limpeza inicial. Registros com mais de dois anos serão removidos ao rodar
-- esta migração; exporte-os antes caso precise manter arquivo próprio.
select app_private.purge_expired_prospections();

-- Se pg_cron já estiver habilitado no Supabase, agenda a limpeza diária.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'lead-control-prospections-retention') then
      perform cron.schedule(
        'lead-control-prospections-retention',
        '17 3 * * *',
        'select app_private.purge_expired_prospections();'
      );
    end if;
  end if;
exception when others then
  raise notice 'Agendamento pg_cron não criado; o trigger de inserção continuará aplicando a retenção.';
end $$;

-- --------------------------------------------------------------------------
-- PERMISSÕES
-- --------------------------------------------------------------------------

revoke all on table public.system_legal_terms from public, anon, authenticated;
revoke all on table public.legal_term_acceptances from public, anon, authenticated;
grant select, insert, update, delete on table public.system_legal_terms to service_role;
grant select, insert, update, delete on table public.legal_term_acceptances to service_role;

revoke all on function app_private.session_user_unchecked(text) from public, anon, authenticated;
revoke all on function app_private.legal_terms_satisfied(uuid, public.app_user_role) from public, anon, authenticated;
revoke all on function app_private.is_valid_cpf(text) from public, anon, authenticated;
revoke all on function app_private.rpc_set_technician_prospection_limit(text, uuid, integer) from public, anon, authenticated;
revoke all on function app_private.rpc_get_required_legal_terms(text) from public, anon, authenticated;
revoke all on function app_private.rpc_accept_legal_terms(text, text, text, text, text, text, text, timestamptz) from public, anon, authenticated;
revoke all on function app_private.rpc_list_legal_acceptances(text) from public, anon, authenticated;
revoke all on function app_private.rpc_get_legal_acceptance_document(text, uuid) from public, anon, authenticated;
revoke all on function app_private.rpc_export_prospections(text, uuid) from public, anon, authenticated;
revoke all on function app_private.purge_expired_prospections() from public, anon, authenticated;
revoke all on function app_private.trigger_purge_expired_prospections() from public, anon, authenticated;

grant execute on function app_private.rpc_get_required_legal_terms(text) to anon, authenticated;
grant execute on function app_private.rpc_set_technician_prospection_limit(text, uuid, integer) to anon, authenticated;
grant execute on function app_private.rpc_accept_legal_terms(text, text, text, text, text, text, text, timestamptz) to anon, authenticated;
grant execute on function app_private.rpc_list_legal_acceptances(text) to anon, authenticated;
grant execute on function app_private.rpc_get_legal_acceptance_document(text, uuid) to anon, authenticated;
grant execute on function app_private.rpc_export_prospections(text, uuid) to anon, authenticated;

revoke all on function public.lc_get_required_legal_terms(text) from public;
revoke all on function public.lc_accept_legal_terms(text, text, text, text, text, text, text, timestamptz) from public;
revoke all on function public.lc_list_legal_acceptances(text) from public;
revoke all on function public.lc_get_legal_acceptance_document(text, uuid) from public;
revoke all on function public.lc_export_prospections(text, uuid) from public;

grant execute on function public.lc_get_required_legal_terms(text) to anon, authenticated;
grant execute on function public.lc_accept_legal_terms(text, text, text, text, text, text, text, timestamptz) to anon, authenticated;
grant execute on function public.lc_list_legal_acceptances(text) to anon, authenticated;
grant execute on function public.lc_get_legal_acceptance_document(text, uuid) to anon, authenticated;
grant execute on function public.lc_export_prospections(text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';

commit;
