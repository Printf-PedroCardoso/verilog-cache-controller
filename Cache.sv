module Cache #(
    parameter int ADDR_WIDTH       = 32,
    parameter int DATA_WIDTH       = 32,
    parameter int LINES            = 16,  // linhas por way
    parameter int WORDS_PER_BLOCK  = 4,
    parameter int WAYS             = 1,   // 1 = direto; 2 = 2-vias
    parameter bit WRITE_BACK       = 1,   // 1=write-back; 0=write-through
    parameter bit WRITE_ALLOCATE   = 1    // 1=write-allocate; 0=no-allocate
) (
    input  logic                     clk,
    input  logic                     rst,

    // Interface CPU
    input  logic                     cpu_req,
    input  logic                     cpu_we,
    input  logic [ADDR_WIDTH-1:0]    cpu_addr,   // endereço por PALAVRA
    input  logic [DATA_WIDTH-1:0]    cpu_wdata,
    output logic [DATA_WIDTH-1:0]    cpu_rdata,
    output logic                     cpu_ready,

    // Interface Memória (simplificada)
    output logic                     mem_req,
    output logic                     mem_we,
    output logic [ADDR_WIDTH-1:0]    mem_addr,   // endereço por PALAVRA
    output logic [DATA_WIDTH-1:0]    mem_wdata,
    input  logic [DATA_WIDTH-1:0]    mem_rdata,
    input  logic                     mem_ready
);
    // Derivados
    localparam int OFFSET_BITS = $clog2(WORDS_PER_BLOCK);
    localparam int INDEX_BITS  = $clog2(LINES);
    localparam int TAG_BITS    = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;

    // Decomposição do endereço
    wire [OFFSET_BITS-1:0] offset = cpu_addr[OFFSET_BITS-1:0];
    wire [INDEX_BITS-1:0]  index  = cpu_addr[OFFSET_BITS +: INDEX_BITS];
    wire [TAG_BITS-1:0]    tag_in = cpu_addr[OFFSET_BITS+INDEX_BITS +: TAG_BITS];

    // Armazenamento (ways x lines x words)
    logic [DATA_WIDTH-1:0] data    [WAYS][LINES][WORDS_PER_BLOCK];
    logic [TAG_BITS-1:0]   tag_arr [WAYS][LINES];
    logic                  valid   [WAYS][LINES];
    logic                  dirty   [WAYS][LINES];

    // LRU para 2-vias: 1 bit por conjunto (0 => way0 mais velho; 1 => way1 mais velho)
    logic                  lru     [LINES];

    // Sinais internos
    logic [WAYS-1:0]       way_hit;
    logic                  hit;
    int                    hit_way;

    // Comparação de tag/valid
    genvar w;
    generate
        for (w = 0; w < WAYS; w++) begin : COMP
            assign way_hit[w] = valid[w][index] && (tag_arr[w][index] == tag_in);
        end
    endgenerate
    assign hit = |way_hit;

    always_comb begin
        hit_way = -1;
        for (int i = 0; i < WAYS; i++) begin
            if (way_hit[i]) hit_way = i;
        end
    end

    // Estado da FSM
    typedef enum logic [2:0] {
        S_IDLE, S_LOOKUP, S_HIT, S_MISS_SELECT, S_WRITEBACK, S_REFILL, S_RESP
    } state_t;
    state_t state, next;

    // Registradores auxiliares
    logic                     req_we_d;
    logic [ADDR_WIDTH-1:0]    req_addr_d;
    logic [DATA_WIDTH-1:0]    req_wdata_d;

    // Vítima / contadores de refill
    int victim_way;
    int refill_cnt; // 0..WORDS_PER_BLOCK-1

    // Saídas padrão
    assign cpu_ready = (state == S_HIT) || (state == S_RESP);

    // Latch de requisição quando entramos em LOOKUP
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            req_we_d    <= 0;
            req_addr_d  <= '0;
            req_wdata_d <= '0;
        end else if (state == S_IDLE && cpu_req) begin
            req_we_d    <= cpu_we;
            req_addr_d  <= cpu_addr;
            req_wdata_d <= cpu_wdata;
        end
    end

    // Reset e inicializações
    integer i, j;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            for (i=0;i<WAYS;i++) begin
                for (j=0;j<LINES;j++) begin
                    valid[i][j] <= 1'b0;
                    dirty[i][j] <= 1'b0;
                    tag_arr[i][j] <= '0;
                end
            end
            for (j=0;j<LINES;j++) lru[j] <= 1'b0;
            mem_req  <= 1'b0; mem_we <= 1'b0; mem_addr <= '0; mem_wdata <= '0;
            cpu_rdata <= '0;
            refill_cnt <= 0; victim_way <= 0;
        end else begin
            state <= next;

            // Exemplo: atualização de LRU em HIT
            if (state == S_HIT && WAYS==2 && hit) begin
                // way acessado torna-se "mais novo"; o outro vira vítima
                lru[index] <= (hit_way == 0) ? 1'b0 : 1'b1; // convenção simples
            end

            // Escrita na cache (write-hit)
            if (state == S_HIT && req_we_d && hit) begin
                data[hit_way][index][offset] <= req_wdata_d;
                if (WRITE_BACK) dirty[hit_way][index] <= 1'b1; // write-back
            end

            // Resposta de leitura na cache (read-hit)
            if (state == S_HIT && !req_we_d && hit) begin
                cpu_rdata <= data[hit_way][index][offset];
            end

            // REFILL: coleta palavras da memória
            if (state == S_REFILL && mem_ready) begin
                data[victim_way][index][refill_cnt] <= mem_rdata;
                if (refill_cnt == WORDS_PER_BLOCK-1) begin
                    valid[victim_way][index]   <= 1'b1;
                    dirty[victim_way][index]   <= 1'b0;
                    tag_arr[victim_way][index] <= tag_in;
                end
            end
        end
    end

    // Próximos estados e controle da memória
    always_comb begin
        next = state;
        mem_req  = 1'b0; mem_we   = 1'b0; mem_addr = '0; mem_wdata = '0;
        cpu_rdata = cpu_rdata; // manter

        unique case (state)
        S_IDLE: begin
            if (cpu_req) next = S_LOOKUP;
        end
        S_LOOKUP: begin
            if (hit) next = S_HIT; else next = S_MISS_SELECT;
        end
        S_HIT: begin
            // Leitura já preparada; Escrita já feita no bloco de seq acima
            next = S_IDLE;
        end
        S_MISS_SELECT: begin
            // Escolher vítima
            if (WAYS == 1) begin
                victim_way = 0;
            end else begin
                // 2-vias: use LRU (1 bit por conjunto) como exemplo
                victim_way = (lru[index] == 1'b0) ? 0 : 1;
            end
            // Se write-back e linha suja, precisa writeback
            if (WRITE_BACK && valid[victim_way][index] && dirty[victim_way][index]) begin
                next = S_WRITEBACK;
            end else begin
                next = S_REFILL;
            end
        
