-- Shared dense float-vector operations for embeddings, aspects, passages,
-- distillation, and subject tags.

const vector = {}

function vector.dot(a, b)
    if a == nil or b == nil or #a != #b then
        return 0.0
    end
    total = 0.0
    for i = 1, #a do
        total = total + a[i] * b[i]
    end
    return total
end

function vector.unit(v, dims)
    if v == nil then
        return nil
    end
    n = #v
    if dims != nil and dims < n then
        n = dims
    end
    if n == 0 then
        return nil
    end
    out = {}
    norm = 0.0
    for i = 1, n do
        out[i] = v[i]
        norm = norm + v[i] * v[i]
    end
    if norm == 0.0 then
        return nil
    end
    norm = math.sqrt(norm)
    for i = 1, n do
        out[i] = out[i] / norm
    end
    return out
end

-- L2-normalises `v` and packs it as little-endian float32 bytes.
function vector.pack(v)
    normalized = vector.unit(v)
    if normalized == nil then
        return nil
    end
    return string.pack("<" .. string.rep("f", #normalized), table.unpack(normalized))
end

function vector.unpack(packed)
    if packed == nil or packed == "" or string.len(packed) % 4 != 0 then
        return nil
    end
    values = {string.unpack("<" .. string.rep("f", string.len(packed) / 4), packed)}
    table.remove(values)
    return values
end

return vector
