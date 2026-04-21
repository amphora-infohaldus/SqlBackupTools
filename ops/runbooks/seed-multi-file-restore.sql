-- Manual seed restore for multi-file DBs that SqlBackupTools silently skips.
-- Run on RESERV-2025 as sysadmin. All files land in C:\Data\ (default).
-- WITH NORECOVERY so the LOG job can take over. CHECKSUM verifies on read.
-- Regenerate file lists with: RESTORE FILELISTONLY FROM DISK = N'<path>';

USE [master];
GO

RESTORE DATABASE [amphorafw_raevv]
FROM DISK = N'C:\SqlBackup\SQL-2022\amphorafw_raevv\FULL\SQL-2022_amphorafw_raevv_FULL_20260420_224232.bak'
WITH NORECOVERY, REPLACE, CHECKSUM,
    MOVE N'amphorafw_raevv_Data' TO N'C:\Data\amphorafw_raevv.mdf',
    MOVE N'amphorafw_raevv_Log1' TO N'C:\Data\amphorafw_raevv_1.ldf',
    MOVE N'amphorafw_raevv_Log2' TO N'C:\Data\amphorafw_raevv_2.ldf';
GO

RESTORE DATABASE [amphorafw_kuusalu_pro]
FROM DISK = N'C:\SqlBackup\SQL-2022\amphorafw_kuusalu_pro\FULL\SQL-2022_amphorafw_kuusalu_pro_FULL_20260420_222208.bak'
WITH NORECOVERY, REPLACE, CHECKSUM,
    MOVE N'amphorafw_kuusalu_Data' TO N'C:\Data\amphorafw_kuusalu_pro.mdf',
    MOVE N'amphorafw_kuusalu_Log2' TO N'C:\Data\amphorafw_kuusalu_pro2.mdf',
    MOVE N'amphorafw_kuusalu_Log'  TO N'C:\Data\amphorafw_kuusalu_pro.ldf';
GO

RESTORE DATABASE [AmphoraInvoicePortal]
FROM DISK = N'C:\SqlBackup\SQL-2022\AmphoraInvoicePortal\FULL\SQL-2022_AmphoraInvoicePortal_FULL_20260420_231511.bak'
WITH NORECOVERY, REPLACE, CHECKSUM,
    MOVE N'AmphoraInvoicePortal'     TO N'C:\Data\AmphoraInvoicePortal.mdf',
    MOVE N'AmphoraInvoicePortal2'    TO N'C:\Data\AmphoraInvoicePortal2.ndf',
    MOVE N'AmphoraInvoicePortal3'    TO N'C:\Data\AmphoraInvoicePortal3.ndf',
    MOVE N'AmphoraInvoicePortal_log' TO N'C:\Data\AmphoraInvoicePortal_log.ldf';
GO

RESTORE DATABASE [prosopos]
FROM DISK = N'C:\SqlBackup\SQL-2022\prosopos\FULL\SQL-2022_prosopos_FULL_20260420_231749.bak'
WITH NORECOVERY, REPLACE, CHECKSUM,
    MOVE N'prosopos_data'    TO N'C:\Data\prosopos.mdf',
    MOVE N'ftrow_ProsoposFT' TO N'C:\Data\ftrow_ProsoposFT.ndf',
    MOVE N'prospos_log'      TO N'C:\Data\prosopos_1.ldf';
GO

RESTORE DATABASE [amphorafw_viljandivv]
FROM DISK = N'C:\SqlBackup\PREMIUM-2022\amphorafw_viljandivv\FULL\PREMIUM-2022_amphorafw_viljandivv_FULL_20260420_220751.bak'
WITH NORECOVERY, REPLACE, CHECKSUM,
    MOVE N'amphorafw_viljandivv_Data'   TO N'C:\Data\amphorafw_viljandivv.mdf',
    MOVE N'amphorafw_viljandivv_1_Data' TO N'C:\Data\amphorafw_viljandivv_1_Data.ndf',
    MOVE N'amphorafw_viljandivv_Log'    TO N'C:\Data\amphorafw_viljandivv_1.ldf';
GO

SELECT name, state_desc, recovery_model_desc
FROM sys.databases
WHERE name IN ('amphorafw_raevv','amphorafw_kuusalu_pro','AmphoraInvoicePortal','prosopos','amphorafw_viljandivv')
ORDER BY name;
GO
