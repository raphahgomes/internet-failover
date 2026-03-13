# Internet Failover Monitor

Sistema automatico de failover de internet **Cabo ↔ 4G USB** com dashboard web, tray icon, alertas WhatsApp/Windows e gerenciamento inteligente de containers Docker.

![Dashboard](screenshots/dashboard.png)

## Funcionalidades

- **Failover automatico**: Detecta queda do cabo e redireciona trafego para modem 4G USB (RNDIS)
- **Failback automatico**: Detecta retorno do cabo e restaura a rota primaria
- **Economia de dados 4G**: Para containers pesados automaticamente ao entrar em 4G, restaura ao voltar pro cabo
- **Dashboard web** em tempo real (`http://localhost:8766`)
- **Tray icon** com cor dinamica (verde=cabo, amarelo=4G, vermelho=sem internet)
- **Alertas WhatsApp** via API local (compativel com Baileys/WhatsApp Web)
- **Notificacoes Windows** (toast notifications)
- **Monitoramento Docker**: Visualizacao de todos os containers com status
- **Log viewer**: Acompanhamento em tempo real dos logs
- **Acoes manuais**: Forcar 4G ou Cabo via dashboard ou tray icon

## Arquitetura

```
internet_failover.ps1          ← Motor principal (roda como SYSTEM)
  ├── Monitora cabo/4G a cada 20s
  ├── Altera metricas de rede para failover
  ├── Para/inicia containers Docker
  ├── Envia alertas WhatsApp + Toast
  └── Grava estado em internet_failover_state.json

internet_failover_monitor.py   ← Monitor visual (roda como usuario)
  ├── Tray icon com cor dinamica
  ├── HTTP server em localhost:8766
  ├── Le state.json do script PS1
  └── Serve dashboard HTML

internet_failover_dashboard.html  ← Dashboard web
  ├── Status em tempo real (polling 3s)
  ├── Cards: modo, cabo, 4G, containers
  ├── Tabela Docker (essenciais vs pesados)
  ├── Botoes: Forcar 4G / Forcar Cabo
  └── Log viewer em tempo real
```

## Requisitos

- Windows 10/11 ou Windows Server 2016+
- PowerShell 5.1+
- Python 3.8+
- Docker (para gerenciamento de containers)
- Modem 4G USB (RNDIS - Remote NDIS Compatible Device)

## Instalacao

### 1. Instalar dependencias Python

```powershell
pip install -r requirements.txt
```

### 2. Configurar o script

Edite `internet_failover.ps1` e ajuste:

```powershell
$CABLE_ALIAS          = "Ethernet 2"     # Nome da interface do cabo
$CABLE_GW             = "192.168.0.1"    # Gateway do cabo
$MODEM_DESC_PATTERN   = "Remote NDIS Compatible"  # Descricao do driver do modem
```

Ajuste as listas de containers essenciais e pesados conforme seu ambiente:

```powershell
$ESSENTIAL_CONTAINERS = @("container1", "container2", ...)
$HEAVY_CONTAINERS     = @("container3", "container4", ...)
```

### 3. Instalar como servico (PowerShell Admin)

```powershell
# Instalar o failover como tarefa agendada (roda como SYSTEM no boot)
.\internet_failover.ps1 -Install

# Instalar o monitor com tray icon (roda como usuario no logon)
python .\internet_failover_monitor.py --install
```

### 4. Verificar status

```powershell
.\internet_failover.ps1 -Status
```

Ou abra o dashboard: http://localhost:8766

## Uso

### Comandos PowerShell (requer admin)

```powershell
.\internet_failover.ps1 -Status      # Ver status atual
.\internet_failover.ps1 -Force4G     # Forcar 4G manualmente
.\internet_failover.ps1 -ForceCable  # Voltar pro cabo manualmente
.\internet_failover.ps1 -Install     # Instalar tarefa agendada
.\internet_failover.ps1 -Uninstall   # Remover tarefa agendada
.\internet_failover.ps1              # Rodar loop de monitoramento
```

### Dashboard Web

Acesse `http://localhost:8766` para:
- Ver status em tempo real de cabo, 4G, internet e containers
- Forcar troca de rede com um clique
- Acompanhar logs em tempo real
- Ver lista completa de containers Docker

### Tray Icon

- **Verde** = Cabo (normal)
- **Amarelo** = 4G Ativo
- **Vermelho** = Sem internet
- Clique direito para menu com acoes rapidas

## Alertas

### WhatsApp
Configure o grupo de alertas em `$WHATSAPP_ALERT_GROUP` no script PS1. Requer container WhatsApp rodando em `localhost:3030`.

### Windows Toast
Notificacoes automaticas ao trocar de modo (cabo → 4G e vice-versa).

## Como funciona o failover

1. Script roda em loop a cada 20 segundos
2. Testa internet com ping em `8.8.8.8` e `1.1.1.1`
3. Se falhar 3x seguidas → aumenta metrica do cabo (200) e reduz metrica do 4G (5)
4. Containers pesados sao parados para economizar dados do 4G
5. Quando gateway do cabo responde 5x seguidas → restaura metricas originais
6. Containers pesados sao reiniciados
7. Alertas WhatsApp e toast sao enviados em cada transicao

## Estrutura de arquivos

```
internet_failover.ps1           # Motor principal do failover
internet_failover_monitor.py    # Monitor com tray icon + HTTP server
internet_failover_dashboard.html # Dashboard web
requirements.txt                # Dependencias Python
internet_failover.log           # Log do failover (gerado)
internet_failover_state.json    # Estado atual (gerado)
```

## Licenca

MIT License
