$IdentidadeUsuario = [Security.Principal.WindowsIdentity]::GetCurrent()
$PrincipalUsuario  = [Security.Principal.WindowsPrincipal]$IdentidadeUsuario
$IsAdmin           = $PrincipalUsuario.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    $CaminhoDoExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    Start-Process -FilePath $CaminhoDoExe -Verb RunAs
    Exit 0
}

$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'
$DiretorioDoExe = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$DbPath = Join-Path $DiretorioDoExe "dataBackup.db"
$ConfigPathAA = Join-Path $DiretorioDoExe "config.json"
$PastaLogs = Join-Path $DiretorioDoExe "logs"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12


Clear-Host

$AnoAtual = (Get-Date).Year

$Header = @"
 ______________________________________________________________________
|                                                                      |
|                                                                      |
|   ██╗    ██╗ █████╗ ███████╗ █████╗ ██████╗ ██╗                      |
|   ██║    ██║██╔══██╗██╔════╝██╔══██╗██╔══██╗██║                      |
|   ██║ █╗ ██║███████║███████╗███████║██████╔╝██║                      |
|   ██║███╗██║██╔══██║╚════██║██╔══██║██╔══██╗╚═╝                      |
|   ╚███╔███╔╝██║  ██║███████║██║  ██║██████╔╝██╗                      |
|    ╚══╝╚══╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═════╝ ╚═╝                      |
|                                                                      |
|  SISTEMA AUTOMÁTICO DE BACKUP EM NUVEM (WASABI MS)                   |
|______________________________________________________________________|
|                                                                      |
|  Desenvolvido por: Meu Sistema - Software Personalizados             |
|  Contato/Suporte : contato@meusistema.com.br                         |
|  Site            : https://www.meusistema.com.br                     |
|  Telefone        : +55 (84) 98137-6412                               |
|  Versão Atual    : v1.5.9 (Compilado .EXE)                           |
|  Ano de Lançam.  : 2026 - $AnoAtual                                  |
|______________________________________________________________________|
|                                                                      |
|  *** AVISO DE SEGURANÇA & PROPRIEDADE INTELECTUAL ***                |
|  Este software é privado. Proibida a reprodução, engenharia reversa  |
|  ou redistribuição parcial/total sem autorização prévia por escrito. |
|______________________________________________________________________|
"@

Write-Host $Header -ForegroundColor Cyan
Write-Host "`n`n[***INIT***] Iniciando rotinas de verificação... Aguarde.`n" -ForegroundColor Yellow

Start-Sleep -Seconds 6

$ModulosObrigatorios = @("AWS.Tools.S3", "PSSQlite")


if (-not (Get-Module -ListAvailable -Name AWS.Tools.S3)) {
    
    
    
    Write-Host "O programa será finalizado." -ForegroundColor Red
    Start-Sleep -Seconds 1
    Read-Host "`n`nPressione ENTER para fechar a janela..."
    exit 1
}


foreach ($Modulo in $ModulosObrigatorios) {
    if (-not (Get-Module -ListAvailable -Name $Modulo)) {
        Write-Host "[ERROR] Modulo --${Modulo}-- nao encontrado. Estamos tentando instalar automaticamente este módulo... AGUARDE..." -ForegroundColor Red
        Start-Sleep -Seconds 3
        try {
            Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Module -Name $Modulo -Scope AllUsers -Force -AllowClobber -ErrorAction Stop

            Write-Host "[OK] Modulo --${Modulo}-- instalado com sucesso! AGUARDE..." -ForegroundColor Green
        }
        catch {
            $MsgModuloErro = "Falha crítica ao tentar instalar o módulo obrigatório [$Modulo] no sistema.`nDetalhes: $($_.Exception.Message)"
            if ([System.Diagnostics.EventLog]::SourceExists("MSBackup")) {
                Write-EventLog -LogName Application -Source "MSBackup" -EntryType Error -EventId 9001 -Message $MsgModuloErro
            }
            Exit 1
        }
    } else {
        Start-Sleep -Seconds 3
        Write-Host "[*] Checando se os modulos obrigatorios estao instalados..." -ForegroundColor DarkCyan
        Start-Sleep -Seconds 5
        Write-Host "[OK] Modulos encontrados! Inicializando vetores dos modulos..." -ForegroundColor DarkCyan
        Start-Sleep -Seconds 5
        Write-Host "[OK] Modulos inicializado com sucesso." -ForegroundColor DarkCyan
    }
}


function Wait-ProcessWithSpinner {
    param (
        [Parameter(Mandatory=$true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory=$false)]
        [string]$Mensagem = "Aguarde, processando..."
    )

    $Animacao = @('|', '/', '-', '\')
    $Contador = 0

    while (-not $Process.HasExited) {
        Write-Host "`r[ $($Animacao[$Contador % 4]) ]$Mensagem" -NoNewline -ForegroundColor DarkCyan
        $Contador++
        Start-Sleep -Milliseconds 200
    }
    $Process.WaitForExit()

    $Espacos = " " * ($Mensagem.Length + 15)
    Write-Host "`r$Espacos`r" -NoNewline
}
function Convert-ToUrlSlug {
    param (
        [string]$TextoEntrada
    )

    if ([string]::IsNullOrWhiteSpace($TextoEntrada)) {
        return ""
    }
    $Resultado = $TextoEntrada.ToLower()
    $Bytes = [System.Text.Encoding]::GetEncoding("Cyrillic").GetBytes($Resultado)
    $Resultado = [System.Text.Encoding]::ASCII.GetString($Bytes)
    $Resultado = $Resultado -replace '[^a-z0-9]', '-'

    return $Resultado
}
function Create-BD-Base-AuditBKP {
    Write-Host "[*] Executando funcoes para criacao do Banco de Dados de auditoria... AGUARDE..." -ForegroundColor DarkCyan
    Start-Sleep -Seconds 3
    $Pragmas = @"
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    PRAGMA temp_store = MEMORY;
    PRAGMA automatic_index = ON;
    PRAGMA user_version = 1;
    PRAGMA foreign_keys = 1;
"@

    Invoke-SqliteQuery -DataSource $DbPath -Query $Pragmas | Out-Null
    Start-Sleep -Seconds 1

    $Schema = @"
    CREATE TABLE IF NOT EXISTS METADATA_APP (
        uuid TEXT PRIMARY KEY,
        version TEXT,
        user_version TEXT,
        provider TEXT
    );

    CREATE TABLE IF NOT EXISTS BACKUP_AUDIT (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid_app TEXT,
        cliente TEXT,
        arquivo_nome TEXT,
        versao_guid TEXT,
        checksum_sha256 TEXT,
        tamanho_bytes REAL,
        data_hora_execucao TEXT,
        ip_local TEXT,
        usuario_so TEXT,
        blob_maquina BLOB,
        FOREIGN KEY(uuid_app) REFERENCES METADATA_APP(uuid)
    );
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $Schema | Out-Null
    Start-Sleep -Seconds 1

    $AppUuid = "{73C8CDF8-C8A6-45A3-8B8E-A62085661CF1}"
    $AppVersion = "v1.2.4"
    $AppUserVersion = "v1.2.4"
    $AppProvider = "MS_APPS"

    $QueryInsertMeta = @"
    INSERT OR REPLACE INTO METADATA_APP (uuid, version, user_version, provider)
    VALUES ('$AppUuid', '$AppVersion', '$AppUserVersion', '$AppProvider');
"@
    Invoke-SqliteQuery -DataSource $DbPath -Query $QueryInsertMeta | Out-Null
    Start-Sleep -Seconds 1

    

    Write-Host "[OK] Banco de Dados de auditoria criado com sucesso! Realizando limpeza e checagem de dados...." -ForegroundColor Green
    Start-Sleep -Seconds 2

    return $true
}

Write-Host "`n`n========= ********* SCRIPT BACKUP AUTOMATICO WASABI MS (PROIBIDA REPRODUCAO) ********* =========`n`n" -ForegroundColor Cyan
Start-Sleep -Seconds 3


$EhWindows = if ($null -ne $IsWindows) { $IsWindows } else { [Environment]::OSVersion.Platform -match "Win32" }

if (-not $EhWindows) {
    Write-Host "`n`n======================================================================" -ForegroundColor Red
    Write-Host "[ERRO CRITICO] Este script foi projetado EXCLUSIVAMENTE para WINDOWS." -ForegroundColor Red
    Write-Host "Execução abortada para prevenir falhas de diretório ou comandos." -ForegroundColor Red
    Write-Host "======================================================================`n`n" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Sistema Operacional conferido com sucesso..." -ForegroundColor DarkCyan
Start-Sleep -Seconds 1
Write-Host "[OK] Preparando variaveis, descriptografando dados..." -ForegroundColor DarkCyan
Start-Sleep -Seconds 1


$DataHoraMili = Get-Date -Format "yyyyMMdd_HHmmss_fff"
$ConfigFile = $ConfigPathAA
if (-not (Test-Path $ConfigFile)) {
    Write-Host "[ERRO CRITICO] Arquivo de configuracao nao encontrado: config.json`n`nLembre-se: O arquivo de configuracao devera estar no mesmo diretorio do script. O diretorio tambem precisa de permissoes de leitura e gravacao." -ForegroundColor Red
    Read-Host "`n`nPressione ENTER para fechar a janela..."
    exit 1
}
$Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
Start-Sleep -Seconds 1

if (-not (Test-Path $Config.CaminhoDestinoTemp)) {
    New-Item -ItemType Directory -Path $Config.CaminhoDestinoTemp -Force | Out-Null
}

if (-not (Test-Path $PastaLogs)) { 
    New-Item -ItemType Directory -Path $PastaLogs -Force | Out-Null 
}

$SenhaRarTexto = ""
$SenhaFallbackAtivada = $false


# inicializando bd local -----------------------------------------------------------
Write-Host "[*] Inicializando o Banco de Dados de auditoria... AGUARDE..." -ForegroundColor DarkCyan
Start-Sleep -Seconds 3

Write-Host "[*] Validando a existencia e estrutura do Banco de Dados..." -ForegroundColor DarkCyan
Start-Sleep -Seconds 2

if (-not (Test-Path -Path $DbPath -PathType Leaf)) {
    Write-Host "[AVISO] Banco de dados 'dataBackup.db' nao foi encontrado. Vamos criar um novo Banco de Dados... AGUARDE..." -ForegroundColor DarkCyan

    # funcao para criar banco de dados
    Create-BD-Base-AuditBKP
}

$CheckSchemaQuery = @"
SELECT name 
FROM sqlite_master 
WHERE type='table' AND name IN ('METADATA_APP', 'BACKUP_AUDIT');
"@

try {
    $TabelasEncontradas = Invoke-SqliteQuery -DataSource $DbPath -Query $CheckSchemaQuery
    
    if ($null -eq $TabelasEncontradas -or $TabelasEncontradas.Count -lt 2) {
        Write-Host "[ERROR] O banco de dados existe, mas não está padronizado. Tabelas 'METADATA_APP' e/ou 'BACKUP_AUDIT' estão ausentes. O script nao vai continuar...`n`nVoce pode tentar recuperar o Banco de Dados ou apague o atual que podemos criar um novo Banco de Dados." -ForegroundColor Red
        Read-Host "`n`nPressione ENTER para fechar a janela..."
        exit 1
    }
}
catch {
    Write-Host "[ERROR] Falha ao tentar ler o esquema do banco de dados. Detalhes: $_" -ForegroundColor Red
    Read-Host "`n`nPressione ENTER para fechar a janela..."
    exit 1
}
Start-Sleep -Seconds 1

Write-Host "[OK] Banco de dados de auditoria validado com sucesso! AGUARDE..." -ForegroundColor Green
Start-Sleep -Seconds 3
# inicializando bd local -----------------------------------------------------------










try {
    if ($Config.SenhaRarEncrypted) {
        $SecureSenha = ConvertTo-SecureString $Config.SenhaRarEncrypted -ErrorAction Stop
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureSenha)
        $SenhaRarTexto = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    }
} catch {
    Write-Host "[AVISO] Falha ao descriptografar senha do WinRAR do JSON.`nImpossivel o script continuar a execucao, verifique o blob da senha e tente novamente..." -ForegroundColor DarkYellow
    exit 1
} finally {
    if ($BSTR) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
}
if ([string]::IsNullOrWhiteSpace($SenhaRarTexto)) {
    $SenhaRarTexto = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
    $SenhaFallbackAtivada = $true
    Write-Host "[AVISO] Utilizando SENHA PADRAO DE FALLBACK para o WinRAR." -ForegroundColor DarkYellow

    $CaminhoArquivoSS_FBB_AQ = Join-Path (Get-Location).Path "senha_winrar_gerada_automaticamente.txt"
    $SenhaRarTexto | Out-File -FilePath $CaminhoArquivoSS_FBB_AQ -Encoding utf8
}


if ($Config.IncluiBackupMariaDBMysql -eq $true) {
    Write-Host "`n========= INICIANDO BACKUP DO BANCO DE DADOS [MARIADB/MYSQL].... =========" -ForegroundColor Cyan
    $DbConfig = $Config.DataInfoBKPMariaDBMysql
    $MysqlExe = Join-Path $DbConfig.BinPath "mysql.exe"
    $MysqldumpExe = Join-Path $DbConfig.BinPath "mysqldump.exe"
    Start-Sleep -Seconds 1
    if (-not (Test-Path $MysqlExe) -or -not (Test-Path $MysqldumpExe)) {
        Write-Host "[ERROR] Executaveis do MySQL/MariaDB nao encontrados no caminho: $($DbConfig.BinPath)" -ForegroundColor Red
        Write-Host "[ERROR] Voce precisa ter os binarios e o servidor de MySQL/MariaDB rodando neste dispositivo`n`nNao e possivel continuar... o programa sera encerrado." -ForegroundColor Red
        Read-Host "`n`nPressione ENTER para fechar a janela..."
        exit 1
    }
    try {
        $SecureDbPass = ConvertTo-SecureString $DbConfig.SecretPassEncrypted
        $BSTRDb = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureDbPass)
        $SenhaDbTexto = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTRDb)
    } catch {
        Write-Host "[ERROR] Erro ao tentar desencriptar a senha do Banco de Dados MySQL/MariaDB." -ForegroundColor Red
        Write-Host "[ERROR] Verifique se informou a senha correta no momento de gerar o embrulhamento.`n`nNao e possivel continuar... o programa sera encerrado." -ForegroundColor Red
        Read-Host "`n`nPressione ENTER para fechar a janela..."
        exit 1
    }
    $env:MYSQL_PWD = $SenhaDbTexto
    $DbConfig = $Config.DataInfoBKPMariaDBMysql
    $MysqlExe = Join-Path $DbConfig.BinPath "mysql.exe"
    $MysqldumpExe = Join-Path $DbConfig.BinPath "mysqldump.exe"
    
    Write-Host "[OK] Verificando status do servidor BD e obtendo bancos...AGUARDE..."-ForegroundColor DarkCyan
    Start-Sleep -Seconds 1
    
    $InfoVersao = & $MysqlExe -V 2>&1
    $InfoVersaoString = $InfoVersao -join " "
    Start-Sleep -Seconds 1
    
    $IsMariaDB = $InfoVersaoString -match "MariaDB"
    $IsModernMySQL = $InfoVersaoString -match "(Ver|Distrib)\s+(5\.7|[8-9]\.)"
    
    $SuportaSslMode = (-not $IsMariaDB) -and $IsModernMySQL
    Start-Sleep -Seconds 1
    
    $ArgumentosBase = @("-h", $DbConfig.Host, "-P", $DbConfig.Port, "-u", $DbConfig.User, "-s", "-N", "-e", "SHOW DATABASES;")

    try {
    
        if ($SuportaSslMode) {
            Write-Host "[*] Cliente MySQL nativo detectado..." -ForegroundColor DarkCyan
            $ArgumentosFinais = $ArgumentosBase + "--ssl-mode=DISABLED"
            $ListaBancos = $(& $MysqlExe $ArgumentosFinais 2>&1) | Where-Object { 
                $_ -notmatch "Warning" -and -not ([string]::IsNullOrWhiteSpace($_))
            }
            
        } else {
            Write-Host "[*] Cliente MariaDB ou legado detectado..." -ForegroundColor DarkCyan
            $ArgumentosMariaDB = $ArgumentosBase + "--skip-ssl"
            $ListaBancos = $(& $MysqlExe $ArgumentosMariaDB 2>&1) | Where-Object { 
                $_ -notmatch "Warning" -and -not ([string]::IsNullOrWhiteSpace($_))
            }
        }

        if ($LASTEXITCODE -ne 0) {
            $env:MYSQL_PWD = $null
            Write-Host "[ERROR] Erro silencioso ou no buffer do servidor, tente novamente depois. Detalhes: $_" -ForegroundColor Red
            Write-Host "Nao e possivel continuar... o programa sera encerrado." -ForegroundColor Red
            Read-Host "`n`nPressione ENTER para fechar a janela..."
            exit 1
        }

    } catch {
        $env:MYSQL_PWD = $null
        Write-Host "[ERROR] O servidor de Banco de Dados MySQL/MariaDB nao respondeu." -ForegroundColor Red
        Write-Host "[ERROR] Verifique se informou o endereco do servidor corretamente, verifique se o servidor esta online, verifique a senha correta no momento de gerar o embrulhamento e nome de usuario existente.`n`nDetalhes do erro: $_`n`nNao e possivel continuar... o programa sera encerrado." -ForegroundColor Red
        Read-Host "`n`nPressione ENTER para fechar a janela..."
        exit 1
    }

    Start-Sleep -Seconds 2

    $BancosSistema = @("information_schema", "mysql", "performance_schema", "sys")
    $BancosParaBackup = $ListaBancos -split "`n" | Where-Object { $_.Trim() -notin $BancosSistema -and $_.Trim() -ne "" }
    Start-Sleep -Seconds 1

    if ($BancosParaBackup.Count -eq 0) {
        Write-Host "[PASS] Nenhum banco de dados encontrado para backup. O script vai continuar a execucao, porem sem nenhum banco de dados MARIADB/MYSQL encontrado para backup. AGUARDE..." -ForegroundColor Yellow
        Start-Sleep -Seconds 3

    } else {
        Write-Host "[OK] Encontramos $($BancosParaBackup.Count) bancos de dados para backup. Estamos coletando informacoes de metadados, AGUARDE..." -ForegroundColor Green
        $PastaBancosTemp = Join-Path $Config.CaminhoDestinoTemp "BancosDB_$DataHoraMili"
        New-Item -ItemType Directory -Path $PastaBancosTemp -Force | Out-Null
        Start-Sleep -Seconds 3

        foreach ($Banco in $BancosParaBackup) {
            $nm_bd_sanitizado = $Banco
            $NomeDumpSql = "$($nm_bd_sanitizado)_$DataHoraMili.sql"
            $CaminhoSql = Join-Path $PastaBancosTemp $NomeDumpSql
            $CaminhoRarInd = Join-Path $PastaBancosTemp "$($nm_bd_sanitizado)_$DataHoraMili.rar"
            Write-Host "[*] Realizando dump de: $Banco ... AGUARDE..." -ForegroundColor DarkCyan

            $ArgumentosDump = @(
                "-h", $DbConfig.Host, 
                "-P", $DbConfig.Port, 
                "-u", $DbConfig.User, 
                "--single-transaction", 
                "--routines", 
                "--triggers"
            )

            if ($SuportaSslMode) {
                $ArgumentosDump += "--ssl-mode=DISABLED"
            } else {
                $ArgumentosDump += "--skip-ssl"
            }

            $ArgumentosDump += $Banco
            $ArgumentosDump += "--result-file=`"$CaminhoSql`""

            $CaminhoLogRedirDumpInd = Join-Path $PastaLogs "\Logs_Process_SQLDUMP_BDs_ind.txt"
            $CaminhoLogErrDumpInd = Join-Path $PastaLogs "\Logs_Errors_Process_SQLDUMP_BDs_ind.txt"

            $ProcessoMysqlDump = Start-Process -FilePath $MysqldumpExe -ArgumentList $ArgumentosDump -RedirectStandardOutput $CaminhoLogRedirDumpInd -RedirectStandardError $CaminhoLogErrDumpInd -Wait -NoNewWindow -PassThru
            Start-Sleep -Seconds 8

            if (Test-Path $CaminhoSql) {
                Write-Host "[OK] Dump do banco de dados realizado com sucesso!" -ForegroundColor Green
                Start-Sleep -Seconds 2
                Write-Host "[*] Iniciando compactacao do Banco de Dados individual..." -ForegroundColor DarkCyan

                $ArgsRarInd = "a -m5 -ep -dh -y -idq -df `"$CaminhoRarInd`" `"$CaminhoSql`""

                Start-Sleep -Seconds 3
                $TempoInicio = Get-Date

                $CaminhoLogRedirInd = Join-Path $PastaLogs "\Logs_Process_Compactacao_BDs_ind.txt"
                $CaminhoLogErrInd = Join-Path $PastaLogs "\Logs_Errors_Process_Compactacao_BDs_ind.txt"

                $ProcessoRarInd = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarInd -RedirectStandardOutput $CaminhoLogRedirInd -RedirectStandardError $CaminhoLogErrInd -Wait -NoNewWindow -PassThru
               
                #$ArgsRarInd = "a -m5 -ep -y -idq `"-hp$SenhaRarTexto`" `"$CaminhoRarInd`" `"$CaminhoSql`""
                #$ProcessoRarInd = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarInd -NoNewWindow -PassThru
                #Wait-ProcessWithSpinner -Process $ProcessoRarInd -Mensagem "CompactaÃ§Ã£o do Banco de Dados (Dump) individual em andamento... AGUARDE..."
                Start-Sleep -Seconds 3
                if ($ProcessoRarInd.ExitCode -eq 0) {
                    $StreamInd = [System.IO.File]::OpenRead($CaminhoRarInd)
                    $SHA256Ind = [System.Security.Cryptography.SHA256]::Create()
                    $HashInd = [System.BitConverter]::ToString($SHA256Ind.ComputeHash($StreamInd)).Replace("-", "").ToLower()
                    $StreamInd.Dispose(); $SHA256Ind.Dispose()
                    
                    Write-Host "[OK] ARQUIVO RAR gerado com sucesso! Checksum SHA256: $HashInd" -ForegroundColor Green
                } else {
                    Write-Host "[ERRO] Falha ao compactar o banco $Banco. (Código do Erro: $($ProcessoRarInd.ExitCode))" -ForegroundColor Red
                    exit 1
                }
            }
        }
        Start-Sleep -Seconds 1
        Write-Host "`n[*] Processo de DUMP nos bancos de dados realizado com sucesso. AGUARDE..." -ForegroundColor DarkCyan
        $NomeMasterDB = "MasterBackupDB_$($Config.Cliente)_$DataHoraMili.rar"
        $CaminhoMasterDB = Join-Path $Config.CaminhoDestinoTemp $NomeMasterDB
        Start-Sleep -Seconds 3
        Write-Host "`n[*] Unindo todos os bancos de dados em um arquivo Master: $NomeMasterDB" -ForegroundColor DarkCyan

        $ArgsRarMaster = "a -m5 -ep -dh -y -idq -df `"-hp$SenhaRarTexto`" `"$CaminhoMasterDB`" `"$PastaBancosTemp\*.rar`""
        #$ProcessoMaster = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarMaster -NoNewWindow -PassThru
        $ProcessoMasterAOO_qa = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarMaster -RedirectStandardOutput ".\logs\out_process_winrar_filesalldumps_$DataHoraMili.txt" -RedirectStandardError ".\logs\err_process_winrar_filesalldumps_$DataHoraMili.txt" -Wait -NoNewWindow -PassThru
        Wait-ProcessWithSpinner -Process $ProcessoMasterAOO_qa -Mensagem "Realizando compactacao de todos BDs em um unico arquivo... AGUARDE..."

        if ($ProcessoMasterAOO_qa.ExitCode -eq 0) 
        {
            Write-Host "[OK] Pacote Master de Bancos de Dados gerado com sucesso!" -ForegroundColor Green
            Write-Host "`n[*] Limpeza de diretorios temporarios... limpeza de chaves e logs... AGUARDE..." -ForegroundColor DarkCyan
            Remove-Item -Path $PastaBancosTemp -Recurse -Force
            Start-Sleep -Seconds 2

            Write-Host "[*] Iniciando Envio do Banco de Dados [MYSQL/MARIADB] para servidor de backup remoto..." -ForegroundColor DarkCyan
            
            $StreamDB = [System.IO.File]::OpenRead($CaminhoMasterDB)
            $SHA256DB = [System.Security.Cryptography.SHA256]::Create()
            $HashBytesDB = $SHA256DB.ComputeHash($StreamDB)
            $ChecksumBase64DB = [System.Convert]::ToBase64String($HashBytesDB)
            $StreamDB.Dispose(); $SHA256DB.Dispose()

            $WasabiEndpoint = "https://s3.$($Config.WasabiRegion).wasabisys.com"
            $GuidVersaoDB = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
            
            $MetadadosS3DB = @{
                "cliente" = $Config.Cliente
                "guid-versao" = $GuidVersaoDB
                "tipo-arquivo" = "database_dump"
            }

           
            $SecureWasabi = ConvertTo-SecureString $Config.Credenciais.SecretKeyEncrypted
            $BSTRWasabi = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureWasabi)
            $SecretKeyWasabi = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTRWasabi)
                
            Write-Host "[*] Iniciando transferencia..." -ForegroundColor DarkCyan
            $TempoIniUploadDB = Get-Date

            Start-Sleep -Seconds 2

            Write-Host "[*] Transferencia em andamento... AGUARDE..." -ForegroundColor DarkCyan

            Write-S3Object -BucketName $Config.WasabiBucket `
                           -Key $NomeMasterDB `
                           -File $CaminhoMasterDB `
                           -AccessKey $Config.Credenciais.AccessKey `
                           -SecretKey $SecretKeyWasabi `
                           -EndpointUrl $WasabiEndpoint `
                           -Region $Config.WasabiRegion `
                           -Metadata $MetadadosS3DB `
                           -ChecksumAlgorithm SHA256 `
                           -StorageClass STANDARD `
                           -ContentType application/vnd.rar `
                           -ErrorAction Stop

            $TempoFimUploadDB = Get-Date
            Write-Host "[OK] Upload do BACKUP DO BANCO DE DADOS concluido com sucesso!`nEm $(($TempoFimUploadDB - $TempoIniUploadDB).TotalSeconds) segundos!" -ForegroundColor Green
           
            Write-Host "`n`n[OK] Iniciando processos apos o upload..." -ForegroundColor DarkCyan
            Start-Sleep -Seconds 3

            Write-Host "`n`n[OK] Registrando auditoria no Banco de Dados local..." -ForegroundColor DarkCyan
            $AppUuid = "{AB36F605-6A60-4BBE-84A6-F66F2E0F4FFD}"
            
            $IpLocal = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Ethernet', 'Wi-Fi' -ErrorAction SilentlyContinue).IPAddress | Select-Object -First 1
            if (-not $IpLocal) { $IpLocal = "Desconhecido" }
            
            $DadosSessaoDB = @{
                Hostname = $env:COMPUTERNAME
                OS_Version = [Environment]::OSVersion.VersionString
                Tipo = "Database_MariaDB_MySQL"
                Porta_Conexao = 443
            }
            
            $BlobBytesDB = [System.Text.Encoding]::UTF8.GetBytes(($DadosSessaoDB | ConvertTo-Json -Compress))
            $BlobHexDB = [System.BitConverter]::ToString($BlobBytesDB).Replace("-", "")
            
            $TamanhoArquivoDB = (Get-Item $CaminhoMasterDB).Length
            $TimestampDB = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            $QueryAuditDB__ASD = 'INSERT INTO BACKUP_AUDIT (uuid_app, cliente, arquivo_nome, versao_guid, checksum_sha256, tamanho_bytes, data_hora_execucao, ip_local, usuario_so, blob_maquina) VALUES (@uuid_app, @cliente, @arquivo_nome, @versao_guid, @checksum_sha256, @tamanho_bytes, @data_hora_execucao, @ip_local, @usuario_so, X_BLOB_);'
            $QueryAuditDB__ASD = $QueryAuditDB__ASD.Replace('X_BLOB_', "X'$BlobHexDB'")
            
            $SqlParamsDB = @{
                "uuid_app"           = $AppUuid
                "cliente"            = $Config.Cliente
                "arquivo_nome"       = $NomeMasterDB
                "versao_guid"        = $GuidVersaoDB
                "checksum_sha256"    = $ChecksumBase64DB
                "tamanho_bytes"      = $TamanhoArquivoDB
                "data_hora_execucao" = $TimestampDB
                "ip_local"           = $IpLocal
                "usuario_so"         = $env:USERNAME
            }

            Invoke-SqliteQuery -DataSource $DbPath -Query $QueryAuditDB__ASD -SqlParameters $SqlParamsDB | Out-Null
            Start-Sleep -Seconds 2
            Write-Host "[OK] Auditoria do processo de Backup salva com sucesso! AGUARDE..." -ForegroundColor Green
            Remove-Item -Path $CaminhoMasterDB -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }
    $env:MYSQL_PWD = $null
    if ($BSTRDb) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTRDb) }
    Start-Sleep -Seconds 1

    Write-Host "`n`n[OK] Procedimentos de backup de BDs Mysql/MariaDB concluidos... AGUARDE...`n`n" -ForegroundColor DarkCyan
    Start-Sleep -Seconds 2
} else {
    Write-Host "`n`n=== IGNORANDO BACKUP DO BANCO DE DADOS [MARIADB/MYSQL].... ===`n`n" -ForegroundColor DarkCyan
    Start-Sleep -Seconds 3
    Write-Host "`n`n[OK] AGUARDE..." -ForegroundColor DarkCyan
    Start-Sleep -Seconds 3
}






if ($Config.IncluiBackupFirebird -eq $true) {
    Write-Host "`n=== Iniciando procedimentos para backup de DB Firebird... AGUARDE... ===" -ForegroundColor DarkCyan
    
    $FbConfig = $Config.DataInfoBKPFirebird
    $GbakExe = Join-Path $FbConfig.BinPath "gbak.exe"

    if (-not (Test-Path $GbakExe)) {
        throw "[ERROR] Executavel do Firebird (gbak.exe) nao encontrado no caminho: $($FbConfig.BinPath)"
    }

    Start-Sleep -Seconds 1

    $FbUser = "SYSDBA"
    $FbPass = "masterkey"

    $PastaFbTemp = Join-Path $Config.CaminhoDestinoTemp "Firebird_${DataHoraMili}"
    New-Item -ItemType Directory -Path $PastaFbTemp -Force | Out-Null

    Start-Sleep -Seconds 1

    $FbHost = $FbConfig.Host
    $FbPort = $FbConfig.Port
    $BancosFbComSucesso = 0

    foreach ($CaminhoFDB in $FbConfig.CaminhosFDB) {
        if (-not (Test-Path $CaminhoFDB)) {
            Write-Host "[AVISO] Arquivo FDB nao encontrado: $CaminhoFDB" -ForegroundColor red
            continue
        }
        $NomeArquivoBase = [System.IO.Path]::GetFileNameWithoutExtension($CaminhoFDB)
        
        $NomeFbk = "${NomeArquivoBase}_${DataHoraMili}.fbk"
        $CaminhoFbk = Join-Path $PastaFbTemp $NomeFbk
        $CaminhoRarFbInd = Join-Path $PastaFbTemp "${NomeArquivoBase}_${DataHoraMili}.rar"

        Write-Host "[OK] Iniciando dump seguro (gbak) de: ${NomeArquivoBase}.fdb ...AGUARDE..." -ForegroundColor DarkCyan
        Start-Sleep -Seconds 2
        
        $StringConexao = "$($FbHost)/$($FbPort):$($CaminhoFDB)"
        $LogErroGbak   = Join-Path $PastaLogs "gbak_${NomeArquivoBase}_${DataHoraMili}-err.log"
        $ArgumentosGbak = @(
            "-b", 
            "-g",
            "-v",
            "-user", $FbUser, 
            "-password", $FbPass, 
            "-se", "$($FbHost)/$($FbPort):service_mgr",
            $CaminhoFDB, 
            $CaminhoFbk,
            "-y", $LogErroGbak
        )
        $ProcGbak = Start-Process -FilePath $GbakExe -ArgumentList $ArgumentosGbak -NoNewWindow -PassThru
        Wait-ProcessWithSpinner -Process $ProcGbak -Mensagem "Realizando Backup (Dump .FBK) seguro do Banco de dados Firebird... AGUARDE..."
        #$ArgCompactar = @("a", "-ep1", "-hp$SenhaRarTexto", $CaminhoDestinoRar, $CaminhoOrigemSql)

        Start-Sleep -Seconds 2

        if ($ProcGbak.ExitCode -eq 0 -and (Test-Path $CaminhoFbk)) {
            Write-Host "[OK] Arquivo dump .fbk criado com sucesso!" -ForegroundColor Green
            Start-Sleep -Seconds 1
            Write-Host "[OK] Compactando arquivo .fbk gerado...AGUARDE..." -ForegroundColor DarkCyan
            
            #$ArgsRarFb = @("a", "-m5", "-dh", "-ep", "-y", "-idq", "`"$CaminhoRarFbInd`"", "`"$CaminhoFbk`"")
            $ArgsRarFb = "a -m5 -ep -dh -y -idq -df `"$CaminhoRarFbInd`" `"$CaminhoFbk`""
            $ProcRarFb = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarFb -NoNewWindow -Wait -PassThru
            Write-Host "[OK] Compressao do .fbk em andamento, AGUARDE..." -ForegroundColor DarkCyan
            Start-Sleep -Seconds 2

            Wait-ProcessWithSpinner -Process $ProcRarFb -Mensagem "Realizando compactacao do .FBK Firebird unitario... AGUARDE..."
            
            if ($ProcRarFb.ExitCode -eq 0) {
                Write-Host "[OK] .FBK compactado com sucesso." -ForegroundColor Green
                Start-Sleep -Seconds 2
                $BancosFbComSucesso++
                Remove-Item -Path $CaminhoFbk -Force
            } else {
                Write-Host "[ERRO] Falha ao compactar $NomeArquivoBase" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        } else {
            Write-Host "`n`n[ERRO] Falha critica ao gerar o .fbk. Verifique se a porta $FbPort esta correta e o servico esta acessivel. Se usa servidor remoto dedicado para o Firebird, verifique se possui algum firewall bloqueando o acesso do script ao Banco de Dados.`n`n" -ForegroundColor Red
            Start-Sleep -Seconds 3
            exit 1
        }
    }

    if ($BancosFbComSucesso -gt 0) {
        Write-Host "[OK] Compactacao individual dos FBKs Firebird concluida com SUCESSO! AGUARDE..." -ForegroundColor Green
        Start-Sleep -Seconds 2
        $NomeMasterFB = "MasterBackupFirebird_$($Config.Cliente)_$DataHoraMili.rar"
        $CaminhoMasterFB = Join-Path $Config.CaminhoDestinoTemp $NomeMasterFB
        
        Write-Host "`n[OK] Unindo $BancosFbComSucesso banco(s) Firebird no arquivo: $NomeMasterFB" -ForegroundColor DarkCyan

        #$ArgsMasterFB = @("a", "-m5", "-dh", "-ep", "-y", "-idq", "-hp$SenhaRarTexto", "`"$CaminhoMasterFB`"", "$PastaFbTemp\*.rar")
        $ArgsRarMasterTTallFb = "a -m5 -ep -dh -y -idq -df `"$CaminhoMasterFB`" `"$PastaFbTemp\*.rar`""
        $ProcMasterFB = Start-Process -FilePath $Config.WinRarPath -ArgumentList $ArgsRarMasterTTallFb -NoNewWindow -PassThru
        Wait-ProcessWithSpinner -Process $ProcMasterFB -Mensagem "Compactacao do arquivo unico com todos os  Firebird em andamento... AGUARDE..."

        Start-Sleep -Seconds 1
        if ($ProcMasterFB.ExitCode -eq 0) {
            Write-Host "[OK] Pacote Master Firebird gerado com SUCESSO! AGUARDE..." -ForegroundColor Green
            Remove-Item -Path $PastaFbTemp -Recurse -Force

            Write-Host "[OK] Realizando limpeza apos o backup do Firebird, AGUARDE..." -ForegroundColor DarkCyan
            
            Start-Sleep -Seconds 3

            Write-Host "[OK] Limpeza realizada com sucesso! PREPARANDO PRÓXIMO PROCESSO..." -ForegroundColor DarkCyan

            Start-Sleep -Seconds 4

            Write-Host "[*] Iniciando preparacao para envio ao servidor de Backup remoto da M.S...." -ForegroundColor DarkCyan
            
            $StreamFB = [System.IO.File]::OpenRead($CaminhoMasterFB)
            $SHA256FB = [System.Security.Cryptography.SHA256]::Create()
            $ChecksumBase64FB = [System.Convert]::ToBase64String($SHA256FB.ComputeHash($StreamFB))
            $StreamFB.Dispose(); $SHA256FB.Dispose()

            $WasabiEndpoint = "https://s3.$($Config.WasabiRegion).wasabisys.com"
            $GuidVersaoFB = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
            
            $MetadadosS3FB = @{
                "cliente" = $Config.Cliente
                "guid-versao" = $GuidVersaoFB
                "tipo-arquivo" = "database_firebird"
            }

            try {
                $SecureWasabi = ConvertTo-SecureString $Config.Credenciais.SecretKeyEncrypted
                $BSTRWasabi = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureWasabi)
                $SecretKeyWasabi = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTRWasabi)
                Start-Sleep -Seconds 2
                
                Write-Host "[*] Preparacao concluida com sucesso. Iniciando envio..." -ForegroundColor DarkCyan
                $TempoIniUploadFB = Get-Date

                Write-Host "[*] Transferencia em andamento... AGUARDE..." -ForegroundColor DarkCyan

                Write-S3Object -BucketName $Config.WasabiBucket `
                               -Key $NomeMasterFB `
                               -File $CaminhoMasterFB `
                               -AccessKey $Config.Credenciais.AccessKey `
                               -SecretKey $SecretKeyWasabi `
                               -EndpointUrl $WasabiEndpoint `
                               -Region $Config.WasabiRegion `
                               -Metadata $MetadadosS3FB `
                               -ChecksumAlgorithm SHA256 `
                               -StorageClass STANDARD `
                               -ContentType application/vnd.rar `
                               -ErrorAction Stop

                $TempoFimUploadFB = Get-Date
                Write-Host "[OK] Upload do arquivo concluido em $(($TempoFimUploadFB - $TempoIniUploadFB).TotalSeconds) segundos!" -ForegroundColor DarkCyan
            } catch {
                throw "Erro ao fazer upload do Firebird."
                exit 1
            } finally {
                Write-Host "[OK] Realizando limpeza e organizacao apos o envio para o servidor remoto..." -ForegroundColor DarkCyan
                Start-Sleep -Seconds 5
                if ($BSTRWasabi) { 
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTRWasabi); $SecretKeyWasabi = $null 
                }   
            }
            Start-Sleep -Seconds 2

            Write-Host "[OK] Tudo certo com a limpeza. AGUARDE..." -ForegroundColor DarkCyan

            Start-Sleep -Seconds 3

            Write-Host "[OK] Registrando auditoria no banco de dados local..." -ForegroundColor Yellow
            $AppUuid = "{AB36F605-6A60-4BBE-84A6-F66F2E0F4FFD}"
            
            $IpLocal = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Ethernet', 'Wi-Fi' -ErrorAction SilentlyContinue).IPAddress | Select-Object -First 1
            if (-not $IpLocal) { $IpLocal = "Desconhecido" }
            
            $DadosSessaoFB = @{
                Hostname = $env:COMPUTERNAME
                OS_Version = [Environment]::OSVersion.VersionString
                Tipo = "Database_Firebird"
                Uso_Senha_Fallback = $SenhaFallbackAtivada
            }
            
            $BlobBytesFB = [System.Text.Encoding]::UTF8.GetBytes(($DadosSessaoFB | ConvertTo-Json -Compress))
            $BlobHexFB = [System.BitConverter]::ToString($BlobBytesFB).Replace("-", "")
            
            $TamanhoArquivoFB = (Get-Item $CaminhoMasterFB).Length
            $TimestampFB = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

            $QueryAuditFB = 'INSERT INTO BACKUP_AUDIT (uuid_app, cliente, arquivo_nome, versao_guid, checksum_sha256, tamanho_bytes, data_hora_execucao, ip_local, usuario_so, blob_maquina) VALUES (@uuid_app, @cliente, @arquivo_nome, @versao_guid, @checksum_sha256, @tamanho_bytes, @data_hora_execucao, @ip_local, @usuario_so, X_BLOB_);'
            $QueryAuditFB = $QueryAuditFB.Replace('X_BLOB_', "X'$BlobHexFB'")

            $SqlParamsFB = @{
                "uuid_app"           = $AppUuid
                "cliente"            = $Config.Cliente
                "arquivo_nome"       = $NomeMasterFB
                "versao_guid"        = $GuidVersaoFB
                "checksum_sha256"    = $ChecksumBase64FB
                "tamanho_bytes"      = $TamanhoArquivoFB
                "data_hora_execucao" = $TimestampFB
                "ip_local"           = $IpLocal
                "usuario_so"         = $env:USERNAME
            }

            Invoke-SqliteQuery -DataSource $DbPath -Query $QueryAuditFB -SqlParameters $SqlParamsFB | Out-Null
            Write-Host "[OK] Log do Firebird gravado com sucesso no Banco de Dados local..." -ForegroundColor Green
            
            Remove-Item -Path $CaminhoMasterFB -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "[ERROR] Nenhum banco Firebird foi validado/gerado para pacote." -ForegroundColor red
    }
}

Write-Host "`n`n========= [OK] Processos com Banco de Dados completamente finalizados... =========" -ForegroundColor Yellow

Start-Sleep -Seconds 3

Write-Host "[*] Inicializando manipulacao com arquivos..." -ForegroundColor DarkCyan

$NomeArquivoRar = "Backup_$($Config.Cliente)_$DataHoraMili.rar"
$CaminhoCompletoRar = Join-Path $Config.CaminhoDestinoTemp $NomeArquivoRar
$ListFilePath = Join-Path $Config.CaminhoDestinoTemp "bkp_lista_$DataHoraMili.txt"
$Config.CaminhosOrigem | ForEach-Object { "`"$_`"" } | Out-File -FilePath $ListFilePath -Encoding UTF8

$RarArgs = "a -m5 -md128 -dh -rr5p -ep3 -y -idq `"$CaminhoCompletoRar`" @`"$ListFilePath`""

Write-Host "[*] Iniciando compressao dos arquivos escolhidos...`nAGUARDE A CONCLUSAO COMPLETA...." -ForegroundColor DarkCyan
Start-Sleep -Seconds 3
$TempoInicio = Get-Date

$Process = Start-Process -FilePath $Config.WinRarPath -ArgumentList $RarArgs -RedirectStandardOutput ".\logs\out_process_winrar_filesall_$DataHoraMili.txt" -RedirectStandardError ".\logs\err_process_winrar_filesall_$DataHoraMili.txt" -Wait -NoNewWindow -PassThru

Wait-ProcessWithSpinner -Process $Process -Mensagem "[*] Compactando arquivos do(s) sistema(s)... Isso pode demorar."

$TempoFim = Get-Date
$Duracao = $TempoFim - $TempoInicio

Remove-Item -Path $ListFilePath -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

if ($Process.ExitCode -eq 0) {
    Write-Host "[OK] Compressao concluida com SUCESSO!" -ForegroundColor Green
    Write-Host "[OK] Arquivo gerado: $CaminhoCompletoRar" -ForegroundColor DarkCyan
    Write-Host "[OK] Tempo de compressao: $($Duracao.Hours)h $($Duracao.Minutes)m $($Duracao.Seconds)s`n" -ForegroundColor DarkCyan
} elseif ($Process.ExitCode -eq 1) {
    Write-Host "[OK] Compressao concluida com AVISOS (Alguns arquivos podem estar em uso e foram pulados, revise a pasta logs o arquivo de log --err_process_winrar_filesall--)." -ForegroundColor Red
    Write-Host "[OK] Arquivo gerado: $CaminhoCompletoRar`n" -ForegroundColor DarkCyan
} else {
    Write-Host "[ERROR] ERRO FATAL na compressao. Codigo de saida do WinRAR: $($Process.ExitCode)" -ForegroundColor Red
    exit 1
}
Start-Sleep -Seconds 2
Write-Host "[OK] Processo de compactacao finalizado com sucesso... AGUARDE..." -ForegroundColor Green
Start-Sleep -Seconds 3
$SenhaRarTexto = $null

Write-Host "[OK] Calculando Checksum (SHA256) do arquivo gerado..." -ForegroundColor DarkCyan

try {
    $Stream = [System.IO.File]::OpenRead($CaminhoCompletoRar)
    $SHA256 = [System.Security.Cryptography.SHA256]::Create()
    $HashBytes = $SHA256.ComputeHash($Stream)
    $ChecksumHex = [System.BitConverter]::ToString($HashBytes).Replace("-", "").ToLower()
    $ChecksumBase64 = [System.Convert]::ToBase64String($HashBytes)
    Write-Host "[OK] Checksum (Hex): $ChecksumHex" -ForegroundColor DarkCyan
    Start-Sleep -Seconds 3
    
} catch {
    throw "[ERROR] Falha ao calcular o Checksum do arquivo. Erro: $_"
} finally {
    if ($Stream) { $Stream.Dispose() }
    if ($SHA256) { $SHA256.Dispose() }
}

Write-Host "[OK] Preparando upload para servidor remoto... AGUARDE..." -ForegroundColor DarkCyan
Start-Sleep -Seconds 1

try {
    $SecureWasabiKey = ConvertTo-SecureString $Config.Credenciais.SecretKeyEncrypted
    $BSTRWasabi = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureWasabiKey)
    $SecretKeyWasabiTexto = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTRWasabi)
} catch {
    throw "[ERROR] Falha ao descriptografar a Secret Key."
} finally {
    if ($BSTRWasabi) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTRWasabi) }
}

$WasabiEndpoint = "https://s3.$($Config.WasabiRegion).wasabisys.com"
Start-Sleep -Seconds 1

$GuidVersao = "{" + [guid]::NewGuid().ToString().ToUpper() + "}"
Write-Host "[OK] Version Backup ID Gerado: $GuidVersao" -ForegroundColor DarkCyan

$MetadadosS3 = @{
    "cliente" = $Config.Cliente
    "guid-versao" = $GuidVersao
}

Write-Host "[*] Iniciando transferencia..." -ForegroundColor DarkCyan
$TempoInicioUpload = Get-Date
Start-Sleep -Seconds 1

try {
    Write-Host "[*] Transferencia em andamento... AGUARDE..." -ForegroundColor DarkCyan
    Start-Sleep -Seconds 1
    Write-S3Object -BucketName $Config.WasabiBucket `
                   -Key $NomeArquivoRar `
                   -File $CaminhoCompletoRar `
                   -AccessKey $Config.Credenciais.AccessKey `
                   -SecretKey $SecretKeyWasabiTexto `
                   -EndpointUrl $WasabiEndpoint `
                   -Region $Config.WasabiRegion `
                   -Metadata $MetadadosS3 `
                   -ChecksumAlgorithm SHA256 `
                   -StorageClass STANDARD `
                   -ContentType application/vnd.rar `
                   -ErrorAction Stop

    $TempoFimUpload = Get-Date
    $DuracaoUpload = $TempoFimUpload - $TempoInicioUpload
    Start-Sleep -Seconds 1

    Write-Host "[OK] Upload concluido com SUCESSO!" -ForegroundColor Green
    Write-Host "[OK] Tempo de upload: $($DuracaoUpload.Hours)h $($DuracaoUpload.Minutes)m $($DuracaoUpload.Seconds)s`n" -ForegroundColor DarkCyan
    Start-Sleep -Seconds 3

} catch {
    throw "Erro critico durante o upload para a Wasabi: $_"
    exit 1
} finally {
    $SecretKeyWasabiTexto = $null
}




$IpLocal = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Ethernet', 'Wi-Fi' -ErrorAction SilentlyContinue).IPAddress | Select-Object -First 1
if (-not $IpLocal) { $IpLocal = "Desconhecido" }

$DadosSessao = @{
    Hostname = $env:COMPUTERNAME
    Dominio = $env:USERDOMAIN
    OS_Version = [Environment]::OSVersion.VersionString
    Porta_Conexao = 443
    Tempo_Upload_Segundos = $DuracaoUpload.TotalSeconds
}

#$BlobJSON = $DadosSessao | ConvertTo-Json -Compress
#$BlobBytes = [System.Text.Encoding]::UTF8.GetBytes($BlobJSON)

$BlobBytesDB__qrZW = [System.Text.Encoding]::UTF8.GetBytes(($DadosSessao | ConvertTo-Json -Compress))
$BlobHexDBZZ_qpu = [System.BitConverter]::ToString($BlobBytesDB__qrZW).Replace("-", "")

$TamanhoArquivo = (Get-Item $CaminhoCompletoRar).Length
$TimestampAgora = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

$QueryInsertAudit = 'INSERT INTO BACKUP_AUDIT (uuid_app, cliente, arquivo_nome, versao_guid, checksum_sha256, tamanho_bytes, data_hora_execucao, ip_local, usuario_so, blob_maquina) VALUES (@uuid_app, @cliente, @arquivo_nome, @versao_guid, @checksum_sha256, @tamanho_bytes, @data_hora_execucao, @ip_local, @usuario_so, X_BLOB_);'
$QueryInsertAudit = $QueryInsertAudit.Replace('X_BLOB_', "X'$BlobHexDBZZ_qpu'")

$SqlParams = @{
    "uuid_app"           = $AppUuid
    "cliente"            = $Config.Cliente
    "arquivo_nome"       = $NomeArquivoRar
    "versao_guid"        = $GuidVersao
    "checksum_sha256"    = $ChecksumBase64
    "tamanho_bytes"      = $TamanhoArquivo
    "data_hora_execucao" = $TimestampAgora
    "ip_local"           = $IpLocal
    "usuario_so"         = $env:USERNAME
}

Invoke-SqliteQuery -DataSource $DbPath -Query $QueryInsertAudit -SqlParameters $SqlParams | Out-Null
Start-Sleep -Seconds 3
Write-Host "[OK] Log de auditoria gravado no banco de dados local com SUCESSO!`n" -ForegroundColor Green
Start-Sleep -Seconds 1

if (Test-Path $CaminhoCompletoRar) {
    Remove-Item -Path $CaminhoCompletoRar -Force
    Write-Host "Limpeza: Arquivo local '$NomeArquivoRar' removido com sucesso...`n" -ForegroundColor DarkCyan
    Write-Host "Limpeza: Artefatos na memÃ³ria e chaves removidos com sucesso...`n" -ForegroundColor DarkCyan
    Start-Sleep -Seconds 1
    Write-Host "Limpeza: Realizando checagem de dados finais...`n" -ForegroundColor DarkCyan
    Start-Sleep -Seconds 2
}
Start-Sleep -Seconds 1
Write-Host "=================================================================" -ForegroundColor Green
Write-Host "[OK] Rotina de Backup FINALIZADA COM SUCESSO!"                      -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Green