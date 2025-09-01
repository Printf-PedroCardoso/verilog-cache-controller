# Cache Controller em SystemVerilog

Este repositório contém a implementação de um **controlador de memória cache** escrito em **SystemVerilog**.  
O módulo é parametrizável e pode ser usado em projetos de arquitetura de computadores para estudo ou prototipagem.

---

## ✨ Funcionalidades

- **Mapeamento**: direto ou 2-vias conjunto-associativo  
- **Políticas de escrita**:
  - Write-back / Write-through
  - Write-allocate / No-allocate
- **Política de substituição**: LRU (para 2 vias)  
- **Parâmetros configuráveis**:
  - Largura do endereço e dos dados
  - Número de linhas
  - Número de palavras por bloco
  - Número de vias (WAYS)

---

## 📂 Estrutura

- `CacheController.sv` → módulo principal da cache

---

## ⚙️ Parâmetros principais

```systemverilog
parameter int ADDR_WIDTH       = 32, // largura do endereço
parameter int DATA_WIDTH       = 32, // largura dos dados
parameter int LINES            = 16, // número de linhas por via
parameter int WORDS_PER_BLOCK  = 4,  // palavras por bloco
parameter int WAYS             = 1,  // 1 = direto, 2 = 2-vias
parameter bit WRITE_BACK       = 1,  // 1 = write-back; 0 = write-through
parameter bit WRITE_ALLOCATE   = 1   // 1 = write-allocate; 0 = no-allocate
