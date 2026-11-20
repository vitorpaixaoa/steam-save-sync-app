# Steam Save Sync

App para Windows que copia o save de um jogo de uma conta Steam para outra(s) no mesmo PC, com poucos cliques.

Útil para quem joga o mesmo jogo em mais de uma conta na mesma máquina (por exemplo, uma conta offline e a conta principal) e quer levar o progresso de uma para a outra.

## O que ele faz

- Lista os jogos **instalados** que têm save em `Steam\userdata` para pelo menos uma conta.
- Mostra as contas com save de cada jogo, com data do último save e tamanho.
- Copia o save de uma conta origem para **uma ou mais contas destino**.
- Faz **backup do destino** antes de sobrescrever, a cada sincronização.
- Valida os arquivos antes de gravar e confere depois da cópia.
- Só sincroniza com o Steam fechado (há um botão para fechá-lo).

## Jogos suportados

| Jogo | AppID | Método |
| --- | --- | --- |
| 007 First Light | 3768760 | Suporte completo (save reassinado para a conta destino) |
| Qualquer outro | - | Cópia simples |

**Cópia simples** copia a pasta `userdata\<conta>\<appid>\remote` sem alterar os arquivos. Funciona em jogos que não vinculam o save à conta. Em jogos que vinculam (ou que guardam o save fora de `userdata`, como em `Documentos` ou `AppData`), o save pode não carregar ou o jogo pode nem aparecer na lista.

## Instalação

Requisitos: Windows 10 ou 11. Não precisa instalar nada além do que já vem no Windows (PowerShell 5.1 e .NET Framework).

1. Baixe o repositório (botão **Code > Download ZIP**) e extraia.
2. Dê dois cliques em `Instalar.cmd`.
3. Abra pelo atalho **Steam Save Sync** na área de trabalho ou no menu Iniciar.

Para usar sem instalar, dê dois cliques em `SaveSync.cmd`. Para remover, use `Desinstalar.cmd`.

## Como usar

1. Feche o Steam.
2. Escolha o jogo na barra lateral.
3. Escolha a conta **origem** e marque os **destinos**.
4. Clique em **Sincronizar** e confirme.
5. Abra o Steam na conta destino. Se aparecer conflito do Steam Cloud, escolha os **arquivos locais**.

A conta destino precisa ter aberto o jogo pelo menos uma vez, para a pasta de save existir.

Backups e preferências ficam em `%LOCALAPPDATA%\SaveSync`.

## Avisos

- Use apenas com as suas próprias contas.
- A cópia pode levar estatísticas e conquistas junto com o progresso. No 007 First Light há uma opção para deixar isso de fora.
- O app só sobrescreve arquivos; ele não apaga slots que existam apenas no destino.
- Projeto sem vínculo com a Valve, a IO Interactive ou qualquer estúdio. Use por sua conta e risco.

## Como adicionar suporte a um jogo

Os perfis ficam na tabela `$script:Profiles`, no início de `SaveSync.ps1`:

```powershell
'3768760' = @{   # 007 First Light
    Method  = 'xor-steamid64'
    Options = @(
        @{ Label = 'Copiar estatísticas e conquistas'; Container = 'LocalProfile' }
    )
}
```

- `Method`: `xor-steamid64` (arquivos `index.save`/`data.save` cifrados com XOR do SteamID64 da conta) ou `copy`.
- `Options`: pastas dentro de `remote` que o usuário pode deixar de fora.

Para um formato novo, adicione um método em `Get-SyncItems`. Rode `powershell -ExecutionPolicy Bypass -File SaveSync.ps1 -SelfTest` para um teste rápido que não grava nada nos saves.

## Créditos

O formato do save do 007 First Light foi documentado pelo projeto [007-First-Light-Save-Tools](https://github.com/Dxian998/007-First-Light-Save-Tools).

## Licença

MIT. Veja `LICENSE`.
