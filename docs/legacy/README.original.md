> Historical project notes. Paths, operational status, badges and test claims below are retained as archival reference and have not all been revalidated. Use the root README and docs/REVIEW.md for this review snapshot.

# MT5 Copy Trade - Master → Slaves

Sistema de copy trading entre múltiplos MetaTrader 5.
Latência mínima via TCP push.

## Arquivos

| Arquivo | Descrição |
|---------|-----------|
| `mt5_copy_server.py` | Servidor Python (HTTP + TCP) |
| `SniperGold.mq5` | EA Master - envia sinais |
| `SlaveTrader.mq5` | EA Slave - recebe e executa |

## Como Usar

### 1. Iniciar o Servidor

```powershell
cd C:\Users\PC\Desktop\webhook-server
python mt5_copy_server.py
```

### 2. MT5 Master (Filtred_EA)

1. Compile `SniperGold.mq5` no MetaEditor (F7)
2. Arraste para o gráfico XAUUSD
3. Configure:
   - Webhook URL: `http://127.0.0.1:8000/trade`
   - Lote inicial: 0.02
4. Autorize WebRequest em: Ferramentas → Opções → Expert Advisors

### 3. MT5 Slave

1. Compile `SlaveTrader.mq5` no MetaEditor (F7)
2. Arraste para o gráfico XAUUSD
3. Configure:
   - Server IP: `127.0.0.1`
   - Server Port: `9999`
   - Master Lot: `0.02`
   - Slave Lot: `0.01`

## Múltiplos Slaves

Pode ter quantos Slaves quiser. Cada um configura seu próprio lote:

| Slave | Lote | Proporção |
|-------|------|-----------|
| Slave 1 | 0.01 | 0.5x |
| Slave 2 | 0.02 | 1x |
| Slave 3 | 0.05 | 2.5x |

## Portas

| Porta | Uso |
|-------|-----|
| 8000 | HTTP - Master envia webhooks |
| 9999 | TCP - Slaves conectam |

## Fluxo

```
Master MT5 → Webhook → Python Server → TCP Push → Slave MT5
   (1-2ms)              (1ms)           (1-3ms)
                     
              Total: ~5-10ms
```
