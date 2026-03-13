# Internet Failover Monitor

Sistema automatizado de failover de internet **Cabo ↔ 4G USB** com dashboard web em tempo real,
tray icon, alertas WhatsApp e gerenciamento inteligente de containers Docker.

![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE?logo=powershell&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.8+-3776AB?logo=python&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Gerenciado-2496ED?logo=docker&logoColor=white)
![License](https://img.shields.io/badge/Licença-MIT-green)

## O que é

Solução completa para ambientes que dependem de **conexão cabo** como primária e **modem 4G USB**
como backup. O sistema opera de forma autônoma: detecta falhas na rede cabeada, redireciona o
tráfego para o modem 4G via manipulação de métricas de interface, para containers Docker pesados
para economizar dados móveis e envia alertas WhatsApp + toast do Windows em cada transição.

## Funcionalidades

- **Failover automático** — detecta queda do cabo e redireciona tráfego para modem 4G USB (RNDIS)
- **Failback automático** — detecta retorno do cabo e restaura a rota primária
- **Economia de dados 4G** — para containers pesados automaticamente ao entrar em 4G
- **Dashboard web** — painel em tempo real com status de rede e containers (`http://localhost:8766`)
- **Tray icon** — ícone na bandeja do Windows com cor dinâmica (verde/amarelo/vermelho)
- **Alertas WhatsApp** — notificações via API local (Baileys/WhatsApp Web)
- **Toast notifications** — alertas nativos do Windows em cada transição de modo
- **Monitoramento Docker** — classificação essencial vs pesado com controle automático
- **Probe ao vivo** — dashboard funciona mesmo sem o script PowerShell rodando

## Como Usar

### Pré-requisitos

- Windows 10/11 ou Windows Server 2016+
- PowerShell 5.1+
- Python 3.8+
- Docker Desktop ou Docker Engine
- Modem 4G USB (RNDIS — Remote NDIS Compatible Device)

### Início Rápido

```powershell
# 1. Clonar
git clone https://github.com/raphahgomes/internet-failover.git
cd internet-failover

# 2. Instalar dependências Python
pip install -r requirements.txt

# 3. Configurar interfaces de rede
# Edite internet_failover.ps1 e ajuste:
#   $CABLE_ALIAS        = "Ethernet 2"
#   $CABLE_GW           = "192.168.0.1"
#   $MODEM_DESC_PATTERN = "Remote NDIS Compatible"

# 4. Instalar como serviço (PowerShell Admin)
.\internet_failover.ps1 -Install           # Failover — roda como SYSTEM no boot
python .\internet_failover_monitor.py --install  # Monitor — roda no logon do usuário

# 5. Verificar status
.\internet_failover.ps1 -Status
```

| Endereço | Descrição |
|----------|-----------|
| http://localhost:8766 | Dashboard web |
| Tray icon (bandeja) | Menu com ações rápidas |

### Comandos

| Comando | Descrição |
|---------|-----------|
| `.\internet_failover.ps1 -Status` | Ver status atual da rede e containers |
| `.\internet_failover.ps1 -Force4G` | Forçar tráfego pelo 4G manualmente |
| `.\internet_failover.ps1 -ForceCable` | Voltar pro cabo manualmente |
| `.\internet_failover.ps1 -Install` | Instalar tarefa agendada (SYSTEM) |
| `.\internet_failover.ps1 -Uninstall` | Remover tarefa agendada |
| `.\internet_failover.ps1` | Rodar loop de monitoramento contínuo |

## Como Funciona

1. Script monitora a cada **20 segundos** com ping em `8.8.8.8` e `1.1.1.1`
2. **3 falhas consecutivas** → altera métrica do cabo (200) e 4G (5) via `Set-NetIPInterface`
3. Containers pesados são parados para economizar dados 4G
4. Quando gateway do cabo responde **5 vezes seguidas** → restaura métricas originais
5. Containers pesados são reiniciados automaticamente
6. Alertas WhatsApp e toast são enviados em cada transição

## Alertas

| Canal | Configuração |
|-------|-------------|
| WhatsApp | Número ou grupo em `$WHATSAPP_ALERT_PHONE` no PS1. Requer container Baileys em `localhost:3030` |
| Windows Toast | Automático em cada mudança de modo (cabo → 4G e vice-versa) |

## Tray Icon

| Cor | Significado |
|-----|-------------|
| Verde | Cabo (operação normal) |
| Amarelo | 4G ativo (failover) |
| Vermelho | Sem internet |

Clique direito no ícone para menu com ações rápidas.

## Estrutura do Projeto

```
internet-failover/
├── internet_failover.ps1            # Motor principal do failover (PowerShell)
├── internet_failover_monitor.py     # Monitor com tray icon + HTTP server (Python)
├── internet_failover_dashboard.html # Dashboard web responsivo
├── requirements.txt                 # Dependências Python (pystray, Pillow)
├── LICENSE
├── internet_failover.log            # Log do failover (gerado em runtime)
└── internet_failover_state.json     # Estado atual em JSON (gerado em runtime)
```

## Stack

| Componente | Tecnologia |
|------------|-----------|
| Failover engine | PowerShell 5.1 |
| Monitor + API | Python 3.8+, pystray, Pillow |
| Dashboard | HTML, CSS, JavaScript |
| Containers | Docker |
| Alertas | WhatsApp (Baileys) + Windows Toast (WinRT) |

## Troubleshooting

| Problema | Solução |
|----------|---------|
| Dashboard mostra tudo DOWN | Verifique se o monitor Python está rodando: `netstat -ano \| findstr 8766` |
| Erro "Acesso negado" nas métricas | Execute o script PS1 como **Administrador** |
| Modem não detectado | Verifique `Get-NetAdapter` — o modem precisa estar com status `Up` |
| Containers não param no 4G | Confirme que os nomes em `$HEAVY_CONTAINERS` batem com `docker ps` |
| Toast não aparece | Windows Server pode não suportar — funciona no Win 10/11 |

## Licença

Distribuído sob a licença MIT. Veja [LICENSE](LICENSE).

## Autor

Desenvolvido por Raphael Gomes — [GitHub](https://github.com/raphahgomes)
