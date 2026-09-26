# Instalação do Online Gateway

O instalador configura o serviço `online-gateway` no systemd. A primeira release, `v1.0.0`, contém um binário para Linux `x86_64`.

## Instalar

Execute o comando abaixo no servidor. Ele baixa o instalador da branch `main` e o executa como root; o script baixa o pacote da release e inicia o serviço.

```bash
wget -qO- https://raw.githubusercontent.com/sshturbo/online-gateway-go/refs/heads/main/install.sh | sudo bash -s
```

Para escolher uma tag específica, passe a versão ao script. Por exemplo:

```bash
wget -qO- https://raw.githubusercontent.com/sshturbo/online-gateway-go/refs/heads/main/install.sh | sudo bash -s -- v1.0.0
```

O instalador cria `/etc/online-service/.env` a partir do `.env.example` e gera `ONLINE_REGISTRY_ENCRYPTION_KEY` se ainda não houver uma chave. O arquivo fica acessível somente ao root. Preserve essa chave em local seguro: ela é necessária para recuperar os segredos guardados no SQLite.

## Consultar o serviço

Ver o estado detalhado:

```bash
sudo systemctl status online-gateway --no-pager
```

Checar apenas se está ativo:

```bash
systemctl is-active online-gateway
```

O resultado esperado é `active`. Para acompanhar os logs recentes:

```bash
sudo journalctl -u online-gateway -n 50 --no-pager
```

Para acompanhar novos logs em tempo real:

```bash
sudo journalctl -u online-gateway -f
```

O serviço usa `127.0.0.1:8085` por padrão. Para conferir se a porta está escutando:

```bash
sudo ss -lntp | grep ':8085'
```
