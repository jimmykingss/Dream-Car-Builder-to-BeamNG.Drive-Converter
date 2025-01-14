local lxp = require("lxp")
local lfs = require("lfs")

local function parse_dream_car_xml(xml_file)
    local namespaces = {xsi = 'http://www.w3.org/2001/XMLSchema-instance'}
    local nodes = {}
    local beams = {}
    local node_dict = {}
    local seat_points = {}
    local beam_weights = {}
    local current_weight = 1
    local beam_deform_value = 1

    local function start_element(parser, name, attrs)
        if name == "XPoint" then
            local node_name = attrs.ind
            local x = tonumber(attrs.x)
            local y = tonumber(attrs.y)
            local z = tonumber(attrs.z)
            table.insert(nodes, {node_name, x, y, z, 0})  -- Initialize weight as 0
            node_dict[node_name] = {x, y, z, 0}  -- Placeholder for weight in node_dict
        elseif name == "XMidPoint" then
            local node_name = attrs.ind
            local ind0 = attrs.ind0
            local ind1 = attrs.ind1
            local kProp0 = 1.0 - tonumber(attrs.kProp0)

            -- Temporarily store the midpoint data
            node_dict[node_name] = {ind0 = ind0, ind1 = ind1, kProp0 = kProp0}
        elseif name == "XPart" then
            local part_type = attrs["xsi:type"]
            if part_type == "XFramePart" or part_type == "XWheelPart" then
                table.insert(beams, {attrs.p0, attrs.p1})
                beam_weights[attrs.p0 .. "-" .. attrs.p1] = current_weight
            elseif part_type == "XManPart" or part_type == "XEnginePart" then
                table.insert(beams, {attrs.p0, attrs.p1})
                table.insert(beams, {attrs.p0, attrs.p2})
                table.insert(beams, {attrs.p1, attrs.p2})
                beam_weights[attrs.p0 .. "-" .. attrs.p1] = current_weight
                beam_weights[attrs.p0 .. "-" .. attrs.p2] = current_weight
                beam_weights[attrs.p1 .. "-" .. attrs.p2] = current_weight
                if part_type == "XManPart" then
                allow_deforms = attrs.allow_deforms or false
                -- Capture seat points for camera setup
                seat_points["seatp0"] = attrs.p0
                seat_points["seatp1"] = attrs.p1
                seat_points["seatp2"] = attrs.p2
                end
            end
        elseif name == "XParam" then
            if attrs.t == "861" then
                current_weight = tonumber(attrs.val) or 1
            elseif attrs.t == "862" then
                beam_deform_value = tonumber(attrs.val) or 1
            elseif attrs.t == "863" then
                strength_value = tonumber(attrs.val) or 1
            end
        end
    end

    local parser = lxp.new({StartElement = start_element})
    local f = io.open(xml_file, "r")
    parser:parse(f:read("*all"))
    parser:close()
    f:close()

    -- Process "XMidPoint" nodes, resolving their positions iteratively until all are calculated
    local midpoints_processed = false
    local retries = 0
    repeat
        midpoints_processed = true
        for node_name, midpoint_data in pairs(node_dict) do
            if midpoint_data.ind0 and midpoint_data.ind1 and midpoint_data.kProp0 then
                local ind0 = midpoint_data.ind0
                local ind1 = midpoint_data.ind1
                local kProp0 = midpoint_data.kProp0

                -- Check if both nodes exist in node_dict
                if node_dict[ind0] and node_dict[ind1] then
                    local x0, y0, z0 = unpack(node_dict[ind0])
                    local x1, y1, z1 = unpack(node_dict[ind1])

                    -- Ensure we have valid node data
                    if x0 and y0 and z0 and x1 and y1 and z1 then
                        local x = x0 + kProp0 * (x1 - x0)
                        local y = y0 + kProp0 * (y1 - y0)
                        local z = z0 + kProp0 * (z1 - z0)

                        table.insert(nodes, {node_name, x, y, z, 0})
                        node_dict[node_name] = {x, y, z, 0}

                        table.insert(beams, {ind0, node_name})
                        table.insert(beams, {node_name, ind1})

                        -- Remove the midpoint data once it's processed
                        node_dict[node_name] = {x, y, z, 0}
                    else
                        -- If node data is invalid, skip processing
                        midpoints_processed = false
                    end
                else
                    -- If the required nodes aren't calculated yet, mark for another pass
                    midpoints_processed = false
                    retries = retries + 1
                    if retries > 500 then
                        print("stopped due to continuous loop. (max 500 retries)")
                        midpoints_processed = true
                    end
                end
            end
        end
    until midpoints_processed

    -- Calculate node weights based on connected beams
    for _, beam in ipairs(beams) do
        local node1, node2 = beam[1], beam[2]
        local key = node1 .. "-" .. node2
        local weight = (beam_weights[key] or 1) * 2
        if node_dict[node1] then
            node_dict[node1][4] = (node_dict[node1][4] or 1) + weight / 2
        end
        if node_dict[node2] then
            node_dict[node2][4] = (node_dict[node2][4] or 1) + weight / 2
        end
    end

    -- Update nodes list with computed weights
    for _, node in ipairs(nodes) do
        local node_name = node[1]
        node[5] = node_dict[node_name][4] or 1  -- Assign calculated weight or default to 0
    end

    return nodes, beams, beam_deform_value, allow_deforms, strength_value, seat_points, node_dict
end

local function insert_nodes_and_beams(config_str, nodes, beams, beam_deform_value, allow_deforms, strength_value, seat_points, node_dict)
    -- Detect the node and beam templates from the config
    local node_template = config_str:match('%[%"Node go here"%s*.-%]')
    if not node_template then
        error("Node template placeholder 'Node go here' not found in config file.")
    end
    
    local beam_template = config_str:match('%[%"Beam go here"%s*.-%]')
    if not beam_template then
        error("Beam template placeholder 'Beam go here' not found in config file.")
    end

    -- Map node weights for easy access
    local node_weights = {}
    for _, n in ipairs(nodes) do
        local node_name = n[1]
        local weight = n[5] or 1
        node_weights[node_name] = weight
    end

    -- Process each beam using the template format
    local beams_str_list = {}
    for _, b in ipairs(beams) do
        local ind0, ind1 = b[1], b[2]

        -- Calculate the weight, hardness, and dampness for each beam based on connected nodes
        local node_weight = ((node_weights[ind0] or 1) + (node_weights[ind1] or 1)) / 2
        local hardness = node_weight * 300000  -- Multiplier for beamSpring
        local dampness = node_weight * 500     -- Updated multiplier for beamDamp

        -- Set beamStrength based on allow_deforms and strength_value
        local beam_strength
        if allow_deforms then
            beam_strength = strength_value * 50000
        else
            beam_strength = '"FLT_MAX"'
        end

        -- Replace placeholders in the beam template
        local beam_entry = beam_template:gsub('"Beam go here"', string.format('"%s", "%s"', ind0, ind1))
        beam_entry = beam_entry:gsub('"Elastic"', tostring(beam_deform_value))
        beam_entry = beam_entry:gsub('"Hardness"', tostring(hardness))
        beam_entry = beam_entry:gsub('"Dampness"', tostring(dampness))
        beam_entry = beam_entry:gsub('"Strength"', tostring(beam_strength))
        
        table.insert(beams_str_list, beam_entry)
    end

    -- Replace "Beams go here" with the generated beams in the config string
    local beams_str = table.concat(beams_str_list, ",\n          ")
    config_str = config_str:gsub('%["Beam go here"%s*.-%]', beams_str)

    -- Process each node using the node template
    local nodes_str_list = {}
    -- Rotate each node 90 degrees on the x-axis and -90 degrees on the z-axis before inserting them
    for _, n in ipairs(nodes) do
        local node_name, x, y, z = n[1], n[2], n[3], n[4]

        -- Apply the first rotation: 90 degrees on X-axis (swap y and z, and negate new y)
        local rotated_y = -z
        local rotated_z = y

        -- Apply the second rotation: -90 degrees on Z-axis (swap x and y, and negate new x)
        local final_x = rotated_y
        local final_y = -x
        local final_z = rotated_z

        -- Replace "Node go here" and "Weight" placeholders in the node entry
        local node_entry = node_template:gsub('"Node go here"', string.format('"%s", %s, %s, %s', node_name, final_x, final_y, final_z))
        node_entry = node_entry:gsub('"Weight"', tostring(n[5] or 1))

        table.insert(nodes_str_list, node_entry)
    end

    -- Replace "Nodes go here" with the full list of nodes
    local nodes_str = table.concat(nodes_str_list, ",\n         ")
    config_str = config_str:gsub('%["Node go here"%s*.-%]', nodes_str)

    -- Replace placeholders in config string
    config_str = config_str:gsub('"seatp0"', '"' .. (seat_points["seatp0"] or "") .. '"')
    config_str = config_str:gsub('"seatp1"', '"' .. (seat_points["seatp1"] or "") .. '"')
    config_str = config_str:gsub('"seatp2"', '"' .. (seat_points["seatp2"] or "") .. '"')

    -- Camera nodes
    local cam_node = node_dict[seat_points["seatp1"]] or {0, 0, 0}

    local camy, camz, camx = cam_node[1], cam_node[2], cam_node[3]
    config_str = config_str:gsub('"curx"', tostring(-camx))
    config_str = config_str:gsub('"cury"', tostring(-camy))
    config_str = config_str:gsub('"curz"', tostring(camz + 0.24))

    config_str = config_str:gsub('"clrx"', tostring(-camx))
    config_str = config_str:gsub('"clry"', tostring(-camy + 0.24))
    config_str = config_str:gsub('"clrz"', tostring(camz))

    -- Camera offset
    -- Retrieve the seat node positions
    local seatp0 = node_dict[seat_points["seatp0"]] or {0, 0, 0}
    local seatp1 = node_dict[seat_points["seatp1"]] or {0, 0, 0}
    local seatp2 = node_dict[seat_points["seatp2"]] or {0, 0, 0}

    -- Calculate the center of the seat nodes
    -- X not used
    --local cam_center_x = (seatp0[3] + seatp1[3] + seatp2[3]) / 3 -- Average X position
    local cam_center_y = (seatp0[1] + seatp1[1] + seatp2[1]) / 3 -- Average Y position
    local cam_center_z = (seatp0[2] + seatp1[2] + seatp2[2]) / 3 -- Average Z position

    -- Heuristic: Determine the orientation of the vehicle
    -- Check the relative positions of the nodes to decide if inversion is needed
    local avg_seat_y = (seatp0[1] + seatp1[1] + seatp2[1]) / 3
    local avg_seat_z = (seatp0[2] + seatp1[2] + seatp2[2]) / 3

    -- Check the signs of the average Y and Z to determine if they need inversion
    local invert_y = avg_seat_y > 0 -- If Y is positive, it needs to be inverted
    local invert_z = avg_seat_z < 0 -- If Z is negative, it needs to be inverted

    -- Apply the calculated inversions
    local cam_offset_y = invert_y and -cam_center_y or cam_center_y
    local cam_offset_z = invert_z and -cam_center_z or cam_center_z

    -- Set the X offset to the X position of seatp1
    local cam_offset_x = seatp1[3]

    -- Format the offset for the configuration
    config_str = config_str:gsub('"camoffsetx"', string.format("%.10f", cam_offset_x))
    config_str = config_str:gsub('"camoffsety"', string.format("%.10f", cam_offset_y))
    config_str = config_str:gsub('"camoffsetz"', string.format("%.10f", cam_offset_z))
    --config_str = config_str:gsub('"camdistance"', string.format("%.6f", adjusted_distance))

    return config_str
end

local function convert_to_jbeam(nodes, beams, beam_deform_value, allow_deforms, strength_value, seat_points, node_dict, output_file, config_file)
    local f = io.open(config_file, "r")
    local config_str = f:read("*all")
    f:close()

    local jbeam_str = insert_nodes_and_beams(config_str, nodes, beams, beam_deform_value, allow_deforms, strength_value, seat_points, node_dict)

    f = io.open(output_file, "w")
    f:write(jbeam_str)
    f:close()
end

local function main()
    local config_file = 'config.json'

    for file in lfs.dir(".") do
        if file:match("%.xml$") then
            local jbeam_output = file:gsub("%.xml$", ".jbeam")
            local nodes, beams, beam_deform_value, allow_deforms, strength_value, seat_points, node_dict = parse_dream_car_xml(file)
            convert_to_jbeam(nodes, beams, beam_deform_value, allow_deforms, strength_value, seat_points, node_dict, jbeam_output, config_file)
            print(string.format("Conversion complete for %s! Saved to %s", file, jbeam_output))
        end
    end
end

main()
