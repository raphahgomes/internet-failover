# 🌐 Internet Failover Monitor

Sistema automatizado de failover de internet **Cabo ↔ 4G USB** com dashboard web em tempo real, tray icon, alertas WhatsApp e gerenciamento inteligente de containers Docker.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE?logo=powershell&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.8+-3776AB?logo=python&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Gerenciado-2496ED?logo=docker&logoColor=white)
![License](https://img.shields.io/badge/Licença-MIT-green)

---

## 🎯 Visão Geral

Solução completa para ambientes que dependem de **conexão cabo** como primária e **modem 4G USB** como backup. O sistema opera de forma autônoma, detectando falhas, redirecionando tráfego e gerenciando containers Docker para economizar dados móveis.

- ✅ **Failover automático**: Detecta queda do cabo e redireciona tráfego para modem 4G USB (RNDIS)
- ✅ **Failback automático**: Detecta retorno do cabo e restaura a rota primária
- ✅ **Economia de dados 4G**: Para containers pesados automaticamente ao entrar em 4G
- ✅ **Dashboard web**: Painel em tempo real com status de rede e containers
- ✅ **Tray icon**: Ícone na bandeja com cor dinâmica (verde/amarelo/vermelho)
- ✅ **Alertas WhatsApp**: Notificações via API local (Baileys/WhatsApp Web)
- ✅ **Toast notifications**: Alertas nativos do Windows em cada transição
- ✅ **Monitoramento Docker**: Classificação essencial vs pesado com controle automático
- ✅ **Probe ao vivo**: Dashboard funciona mesmo sem o script PS1 rodando

---

## 🏗️ Arquitetura

```
┌─────────────────────────────────────────────────────────────┐
│                    internet_failover.ps1                     │
│                  (Roda como SYSTEM no boot)                  │
│                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐ │
│  │ Monitor     │  │ Failover     │  │ Docker Manager     │ │
│  │ cabo/4G     │──│ metrica rede │──│ start/stop         │ │
│  │ a cada 20s  │  │ automatico   │  │ containers         │ │
│  └─────────────┘  └──────────────┘  └────────────────────┘ │
│            │                │                               │
│            ▼                ▼                               │
│  ┌─────────────────────────────────────┐                   │
│  │ internet_failover_state.json        │                   │
│  │ internet_failover.log               │                   │
│  └─────────────────────────────────────┘                   │
│            │                │                               │
│            ▼                ▼                               │
│  ┌─────────────┐  ┌──────────────┐                         │
│  │ WhatsApp    │  │ Windows      │                         │
│  │ Alert API   │  │ Toast        │                         │
│  └─────────────┘  └──────────────┘                         │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│              internet_failover_monitor.py                    │
│               (Roda como usuário no logon)                   │
│                                                             │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐ │
│  │ Tray Icon   │  │ HTTP Server  │  │ Live Probe         │ │
│  │ cor dinâmica│  │ :8766        │  │ (fallback se PS1   │ │
│  │ menu ações  │  │ REST API     │  │  não estiver ativo)│ │
│  └─────────────┘  └──────────────┘  └────────────────────┘ │
│                          │                                  │
│                          ▼                                  │
│  ┌─────────────────────────────────────┐                   │
│  │ internet_failover_dashboard.html    │                   │
│  │ Cards · Containers · Logs · Ações   │                   │
│  └─────────────────────────────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

---

## 🚀 Início Rápido

### Pré-requisitos

- Windows 10/11 ou Windows Server 2016+
- PowerShell 5.1+
- Python 3.8+
- Docker Desktop ou Docker Engine
- Modem 4G USB (RNDIS — Remote NDIS Compatible Device)

### Instalação

1. **Clonar o repositório**

```powershell
git clone https://github.com/raphahgomes/internet-failover.git
cd internet-failover
```

2. **Instalar dependências Python**

```powershell
pip install -r requirements.txt
```

3. **Configurar interfaces de rede**

Edite `internet_failover.ps1` e ajuste conforme seu ambiente:

```powershell
$CABLE_ALIAS          = "Ethernet 2"               # Nome da interface do cabo
$CABLE_GW             = "192.168.0.1"               # Gateway do cabo
$MODEM_DESC_PATTERN   = "Remote NDIS Compatible"    # Descrição do driver do modem
```

Ajuste as listas de containers essenciais e pesados:

```powershell
$ESSENTIAL_CONTAINERS = @("container1", "container2", ...)
$HEAVY_CONTAINERS     = @("container3", "container4", ...)
```

4. **Instalar como serviço (PowerShell Admin)**

```powershell
# Failover como tarefa agendada — roda como SYSTEM no boot
.\internet_failover.ps1 -Install

# Monitor com tray icon — roda como usuário no logon
python .\internet_failover_monitor.py --install
```

5. **Verificar status**

```powershell
.\internet_failover.ps1 -Status
```

Ou abra o dashboard: **http://localhost:8766**

---

## 🔧 Comandos Úteis

### PowerShell (requer admin)

| Comando | Descrição |
|---------|-----------|
| `.\internet_failover.ps1 -Status` | Ver status atual da rede e containers |
| `.\internet_failover.ps1 -Force4G` | Forçar tráfego pelo 4G manualmente |
| `.\internet_failover.ps1 -ForceCable` | Voltar pro cabo manualmente |
| `.\internet_failover.ps1 -Install` | Instalar tarefa agendada (SYSTEM) |
| `.\internet_failover.ps1 -Uninstall` | Remover tarefa agendada |
| `.\internet_failover.ps1` | Rodar loop de monitoramento contínuo |

### Dashboard Web

Acesse `http://localhost:8766` para:
- Ver status em tempo real de cabo, 4G, internet e containers
- Forçar troca de rede com um clique
- Acompanhar logs em tempo real
- Ver lista completa de containers Docker com classificação

### Tray Icon

| Cor | Significado |
|-----|-------------|
| 🟢 Verde | Cabo (operação normal) |
| 🟡 Amarelo | 4G Ativo (failover) |
| 🔴 Vermelho | Sem internet |

Clique direito no ícone para menu com ações rápidas.

---

## ⚙️ Como Funciona o Failover

```
Cable OK ──────── ✓ ────── Internet OK ──── modo: cabo (normal)
                                              │
Cable FAIL ──── 3x falha ───── habilita 4G ──┤ modo: 4g (failover)
                                              │  ├── Para containers pesados
                                              │  └── Envia alerta WhatsApp + Toast
                                              │
Cable VOLTA ── 5x gateway OK ── restaura ────── modo: cabo (recovered)
                                                 ├── Reinicia containers pesados
                                                 └── Envia alerta de recuperação
```

1. Script monitora a cada **20 segundos**
2. Testa internet com ping em `8.8.8.8` e `1.1.1.1`
3. **3 falhas consecutivas** → altera métrica do cabo (200) e 4G (5) via `Set-NetIPInterface`
4. Containers pesados são parados para economizar dados 4G
5. Quanto gateway do cabo responde **5x seguidas** → restaura métricas originais
6. Containers pesados são reiniciados automaticamente
7. Alertas WhatsApp e toast são enviados em cada transição

---

## 📡 Alertas

### WhatsApp
Configure o grupo de alertas em `$WHATSAPP_ALERT_GROUP` no script PS1. Requer container WhatsApp (Baileys) rodando em `localhost:3030`.

### Windows Toast
Notificações nativas do Windows disparadas automaticamente em cada mudança de modo (cabo → 4G e vice-versa).

---

## 📁 Estrutura do Projeto

```
internet-failover/
├── internet_failover.ps1          # Motor principal do failover (PowerShell)
├── internet_failover_monitor.py   # Monitor com tray icon + HTTP server (Python)
├── internet_failover_dashboard.html # Dashboard web responsivo
├── requirements.txt               # Dependências Python (pystray, Pillow)
├── internet_failover.log          # Log do failover (gerado em runtime)
└── internet_failover_state.json   # Estado atual em JSON (gerado em runtime)
```

---

## 🔒 Segurança

- ✅ Dashboard acessível apenas em `localhost` (127.0.0.1)
- ✅ Script de failover roda como SYSTEM com privilégios restritos
- ✅ Alertas WhatsApp via API local — sem tokens expostos
- ✅ Nenhum dado sensível nos logs

---

## 🐛 Troubleshooting

| Problema | Solução |
|----------|---------|
| Dashboard mostra tudo DOWN | Verifique se o monitor Python está rodando: `netstat -ano \| findstr 8766` |
| Erro "Acesso negado" nas métricas | Execute o script PS1 como **Administrador** |
| Modem não detectado | Verifique `Get-NetAdapter` — o modem precisa estar com status `Up` |
| Containers não param no 4G | Confirme que os nomes em `$HEAVY_CONTAINERS` batem com `docker ps` |
| Toast não aparece | Windows Server pode não suportar — funciona no Win 10/11 |

---

## 📄 Licença

MIT License — TSC Express

---

**Versão**: 1.0  
**Última Atualização**: 13/03/2026  
**Stack**: PowerShell 5.1 · Python 3.8+ · HTML/CSS/JS · Docker
