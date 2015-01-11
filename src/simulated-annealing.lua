--- An implementation of Simulated Annealing for FCEUX Lua Script to search input sequence automatically.
-- Written by nodchip
-- 2014, December 24th.
local START_FRAME = 196;
local HARDNESS = 1e-0;
local TIME_LIMIT_SECS = 10.0;
local FRAMES_PER_WINDOW = 10;

local MODE_UNKNOWN = 0;
local MODE_CHANGE = 1;

local INVALID = -1;

local INPUT_A = 0x01;
local INPUT_B = 0x02;
local INPUT_SELECT = 0x04;
local INPUT_START = 0x08;
local INPUT_UP = 0x10;
local INPUT_DOWN = 0x20;
local INPUT_LEFT = 0x40;
local INPUT_RIGHT = 0x80;

local PROBABILITY_A = 0.9;
local PROBABILITY_B = 0.9;
local PROBABILITY_SELECT = 0.0;
local PROBABILITY_START = 0.0;
local PROBABILITY_UP = 0.0;
local PROBABILITY_DOWN = 0.0;
local PROBABILITY_LEFT = 0.0;
local PROBABILITY_RIGHT = 0.9;

local INPUT_TO_PROBABILITY = {
  [INPUT_A] = PROBABILITY_A,
  [INPUT_B] = PROBABILITY_B,
  [INPUT_SELECT] = PROBABILITY_SELECT,
  [INPUT_START] = PROBABILITY_START,
  [INPUT_UP] = PROBABILITY_UP,
  [INPUT_DOWN] = PROBABILITY_DOWN,
  [INPUT_LEFT] = PROBABILITY_LEFT,
  [INPUT_RIGHT] = PROBABILITY_RIGHT,
};

local SEARCH_WINDOW_SIZE = 4 * 60;
local SEARCH_STEP = 60;

local NUMBER_OF_PLAYERS = 1;

--------------------------------------------------------------------------------
-- Logging
--------------------------------------------------------------------------------

local LEVEL_SEVERE = 0;
local LEVEL_WARNING = 1;
local LEVEL_INFO = 2;
local LEVEL_CONFIG = 3;
local LEVEL_FINE = 4;
local LEVEL_FINER = 5;
local LEVEL_FINEST = 6;

local LOGGING_LEVEL = LEVEL_INFO;

--- Prints the argument if the level <= LOGGING_LEVEL
-- @param #number level Logging level
local function log(level, ...)
  if level <= LOGGING_LEVEL then
    print(...)
  end
end

--- Prints the argument if the LEVEL_SEVERE <= LOGGING_LEVEL
local function severe(...)
  log(LEVEL_SEVERE, ...);
end

--- Prints the argument if the LEVEL_WARNING <= LOGGING_LEVEL
local function warning(...)
  log(LEVEL_WARNING, ...);
end

--- Prints the argument if the LEVEL_INFO <= LOGGING_LEVEL
local function info(...)
  log(LEVEL_INFO, ...);
end

--- Prints the argument if the LEVEL_CONFIG <= LOGGING_LEVEL
local function config(...)
  log(LEVEL_CONFIG, ...);
end

--- Prints the argument if the LEVEL_FINE <= LOGGING_LEVEL
local function fine(...)
  log(LEVEL_FINE, ...);
end

--- Prints the argument if the LEVEL_FINER <= LOGGING_LEVEL
local function finer(...)
  log(LEVEL_FINER, ...);
end

--- Prints the argument if the LEVEL_FINEST <= LOGGING_LEVEL
local function finest(...)
  log(LEVEL_FINEST, ...);
end

--------------------------------------------------------------------------------
-- Input and input sequence library.
--------------------------------------------------------------------------------

--- Generates a random input (the combination of pushed buttons)
-- @return #number Random input. The return value can be passed to taseditor.submitinputchange().
local function generateRandomInput()
  finer("generateRandomInput()");

  input = 0;
  for key, probability in pairs(INPUT_TO_PROBABILITY) do
    local r = math.random();
    finest(key, probability, r);
    if r < probability then
      input = OR(input, key);
    end
  end
  finest(input);
  return input;
end

--- Generates the sequence of random input (the combinations of pushed buttons) for each joypad
-- @param #number startFrame Frame number of the start frame.
-- @param #number endFrame Frame number of the end frame. The input of this frame is not generated.
-- @return #map<#number,#map<#number,#number> > Map from frame numbers to input for each joypad.
local function generateRandomInputSequences(startFrame, endFrame)
  finer(string.format("generateRandomInputSequences(%d, %d)", startFrame, endFrame));

  local inputSequences = {}
  for joypad = 1, NUMBER_OF_PLAYERS do
    local inputSequence = {};
    for frame = startFrame, endFrame - 1, FRAMES_PER_WINDOW do
      inputSequence[frame] = generateRandomInput();
    end
    inputSequences[joypad] = inputSequence;
  end

  return inputSequences;
end

--- Sets the sequence of input (the combinations of pushed buttons) to the TAS Editor for each joypad
-- @param #number startFrame Frame number of the start frame.
-- @param #number endFrame Frame number of the end frame. The input of this frame is not generated.
local function setInputSequences(startFrame, endFrame, inputSequences)
  finer(string.format("setInputSequences(%d, %d, ...)", startFrame, endFrame));

  -- Set the playback frame to startFrame
  -- to avoid the "cannot resume non-suspended coroutine" error.
  taseditor.setplayback(0);

  for joypad = 1, NUMBER_OF_PLAYERS do
    local inputSequence = inputSequences[joypad];
    for frame = startFrame, endFrame - 1, FRAMES_PER_WINDOW do
      for delta = 0, FRAMES_PER_WINDOW - 1 do
        local input = inputSequence[frame];
        -- Please uncomment out to fire the B button.
--        input = AND(input, 0xff - INPUT_B);
--        if (frame + delta) % 2 == 0 then
--          input = OR(input, INPUT_B);
--        end
        taseditor.submitinputchange(frame + delta, joypad, input);
      end
    end
  end

  taseditor.applyinputchanges();
end

--- Gets the sequence of input (the combinations of pushed buttons) from the TAS Editor for each joypad
-- @param #number startFrame Frame number of the start frame.
-- @param #number endFrame Frame number of the end frame. The input of this frame is not set.
-- @return #map<#number,#map<#number,#number> > Map from frame numbers to input for each joypad.
local function getInputSequences(startFrame, endFrame)
  finer("getInputSequences()");

  local inputSequences = {};
  for joypad = 1, NUMBER_OF_PLAYERS do
    local inputSequence = {};
    for frame = startFrame, endFrame - 1 do
      local input = taseditor.getinput(frame, joypad);
      finest(string.format("joypad:%d frame:%d input:%d", joypad, frame, input));
      if input == -1 then
        input = 0;
      end
      inputSequence[frame] = input;
    end
    inputSequences[joypad] = inputSequence;
  end

  return inputSequences;
end

--------------------------------------------------------------------------------
-- Simulated Anneling library
--------------------------------------------------------------------------------

--- Calculates the propbability that a state is transit to its neighbor state
-- @param #number energy Energy of the current state
-- @param #number energyNeighbor Energy of the neighbor state
-- @param #number temperature Current temperature
-- @return #number Probability
local function calculateProbability(energy, energyNeighbor, temperature)
  finer("calculateProbability()");

  if energyNeighbor < energy then
    return 1.0;
  else
    local result = math.exp((energy - energyNeighbor) / (temperature + 1e-9) * HARDNESS);
    fine(string.format("%f -> %f * %f = %f", energy, energyNeighbor, temperature, result));
    return result;
  end
end

--- Generates an initial state.
-- The initial state contains the frame numbers of the start frame, the frame
-- number of the end frame and the sequence of input (the combinations of
-- pushed buttons).
-- @param #number startFrame Frame number of the start frame
-- @param #number endFrame Frame number of the end frame
-- @return #table Initial state
local function generateInitialState(startFrame, endFrame)
  finer("generateInitialState()");

  local inputSequences = getInputSequences(startFrame, endFrame);
  return {
    startFrame = startFrame,
    endFrame = endFrame,
    inputSequences = inputSequences;
  };
end

--- Returns a random frame number between startFrame (inclusive) and endFrame (exclusive)
-- @param #number startFrame Frame number of the start frame
-- @param #number endFrame Frame number of the end frame
-- @return #number Random frame number. (The return end frame number - startFrame) is divisible by FRAMES_PER_WINDOW.
local function getRandomFrame(startFrame, endFrame)
  return math.random(0, (endFrame - startFrame) / FRAMES_PER_WINDOW - 1) * FRAMES_PER_WINDOW + startFrame;
end

--- Generates a neibor state of a given state.
-- There are several pattern how the sequence of input are changed.
-- 1. A input in the sequence is changed.
-- 2. Two input in the sequence are swapped.
-- 3. Three input in the sequence are swapped.
-- 4. A input is inserted into the sequence.
-- 5. A input is removed from the sequence.
-- @param #state state Given state
local function generateNeighborState(state)
  finer("generateNeighborState()");

  local startFrame = state.startFrame;
  local endFrame = state.endFrame;
  local neighborState = nil;
  while true do
    local joypad = math.random(1, NUMBER_OF_PLAYERS);
    local mode = math.random(5);
    if mode == 1 then
      -- Change a input in inputSequence.
      local frame = getRandomFrame(startFrame, endFrame);
      local input = generateRandomInput();
      if state.inputSequences[joypad][frame] ~= input then
        info(string.format("Change joypad:%d frame:%d %d -> %d", joypad, frame, state.inputSequences[joypad][frame], input));
        local inputSequence = copytable(state.inputSequences[joypad]);
        inputSequence[frame] = input;
        local inputSequences = copytable(state.inputSequences);
        inputSequences[joypad] = inputSequence;
        return {
          startFrame = startFrame,
          endFrame = endFrame,
          inputSequences = inputSequences
        };
      end
      
    elseif mode == 2 then
      -- Swap 2 input.
      local frame1 = getRandomFrame(startFrame, endFrame);
      local frame2 = getRandomFrame(startFrame, endFrame);
      if state.inputSequences[joypad][frame1] ~= state.inputSequences[joypad][frame2] then
        info(string.format("Swap joypad:%d frame:%d <-> %d", joypad, frame1, frame2));
        local inputSequence = copytable(state.inputSequences[joypad]);
        local temp = inputSequence[frame1];
        inputSequence[frame1] = inputSequence[frame2];
        inputSequence[frame2] = temp;
        local inputSequences = copytable(state.inputSequences);
        inputSequences[joypad] = inputSequence;
        return {
          startFrame = startFrame,
          endFrame = endFrame,
          inputSequences = inputSequences
        };
      end
      
    elseif mode == 3 then
      -- Swap 3 input.
      local frame1 = getRandomFrame(startFrame, endFrame);
      local frame2 = getRandomFrame(startFrame, endFrame);
      local frame3 = getRandomFrame(startFrame, endFrame);
      if state.inputSequences[joypad][frame1] ~= state.inputSequences[joypad][frame2] and
         state.inputSequences[joypad][frame2] ~= state.inputSequences[joypad][frame3] and
         state.inputSequences[joypad][frame3] ~= state.inputSequences[joypad][frame1] then
        info(string.format("Swap joypad:%d frame:%d <-> %d <-> %d", joypad, frame1, frame2, frame3));
        local inputSequence = copytable(state.inputSequences[joypad]);
        local temp = inputSequence[frame1];
        inputSequence[frame1] = inputSequence[frame2];
        inputSequence[frame2] = inputSequence[frame3];
        inputSequence[frame3] = temp;
        local inputSequences = copytable(state.inputSequences);
        inputSequences[joypad] = inputSequence;
        return {
          startFrame = startFrame,
          endFrame = endFrame,
          inputSequences = inputSequences
        };
      end
      
    elseif mode == 4 then
      -- Insert a input.
      local insertionFrame = getRandomFrame(startFrame, endFrame);
      local input = generateRandomInput();
      info(string.format("Insert joypad:%d frame:%d input:%d", joypad, insertionFrame, input));
      local inputSequence = copytable(state.inputSequences[joypad]);
      for frame = endFrame - 1, insertionFrame + 1, -1 do
        inputSequence[frame] = inputSequence[frame - 1];
      end
      inputSequence[insertionFrame] = input;
      local inputSequences = copytable(state.inputSequences);
      inputSequences[joypad] = inputSequence;
      return {
        startFrame = startFrame,
        endFrame = endFrame,
        inputSequences = inputSequences
      };
      
    elseif mode == 5 then
      -- Remove a input.
      local removedFrame = getRandomFrame(startFrame, endFrame);
      local input = generateRandomInput();
      info(string.format("Remove joypad:%d frame:%d input:%d", joypad, removedFrame, input));
      local inputSequence = copytable(state.inputSequences[joypad]);
      for frame = removedFrame, endFrame - 2 do
        inputSequence[frame] = inputSequence[frame + 1];
      end
      inputSequence[endFrame] = input;
      local inputSequences = copytable(state.inputSequences);
      inputSequences[joypad] = inputSequence;
      return {
        startFrame = startFrame,
        endFrame = endFrame,
        inputSequences = inputSequences
      };
    end
  end
end

--- Calculates the energy of a given state.
-- This functions calculates the energy by the following process.
-- 1. Sets the sequence of input to the TAS Editor.
-- 2. Sets the playback frame to startFrame.
-- 3. Lets the emulator to emulate from startFrame (inclusive) to endFrame (exlusive).
-- 4. Retrieves the coordinates of the Mario.
-- 5. Returns the x-coordinates of the Mario multiplied by -1.0.
-- Note that the state will be transit to lower energy.
-- @param #number state Given state
local function calculateEnergy(state)
  finer("calculateEnergy()");
  finest("state", state);

  local startFrame = state.startFrame;
  local endFrame = state.endFrame;
  setInputSequences(startFrame, endFrame, state.inputSequences);
  
  finest("taseditor.setplayback(startFrame);");
  taseditor.setplayback(startFrame);

  -- For Super Mario Bros.  
  for frame = startFrame, endFrame - 1 do
    finest("emu.frameadvance();");
    emu.frameadvance();
    finest("emu.frameadvance(); exit");
  end

  finest("mx");
  local mx = memory.readbyte(0x0086)+(255*memory.readbyte(0x006D));
  local my = memory.readbyte(0x00CE);

  return -1.0 * mx;

  -- For Balloon Fight.
--  local previousC9 = memory.readbyte(0x00c9);
--  finest("previousC9", previousC9);
--  local shift = 0;
--  for frame = startFrame, endFrame - 1 do
--    finest("emu.frameadvance();");
--    emu.frameadvance();
--    finest("emu.frameadvance(); exit");
--
--    local c9 = memory.readbyte(0x00c9);
--    if previousC9 == 0xff and c9 == 0 then
--      shift = shift + 256;
--    end
--    previousC9 = c9;
--    finest("previousC9", previousC9);
--  end
--  
--  return -10.0 * (previousC9 + shift) + math.max(0, math.abs(y - 96) - 64);

  -- For TwinBee.
--  for frame = startFrame, endFrame - 1 do
--    finest("emu.frameadvance();");
--    emu.frameadvance();
--    finest("emu.frameadvance(); exit");
--
--    local rest = memory.readbyte(0x0080);
--    finest("rest", rest);
--    if rest ~= 3 then
--      return -100.0 * frame;
--    end
--
--    local death = memory.readbyte(0x0012);
--    finest("death", rest);
--    if death == 51 then
--      return -100.0 * frame;
--    end
--  end
--
--  local x = memory.readbyte(0x00c3);
--  local y = memory.readbyte(0x00c4);
--  return -100.0 * endFrame + math.abs(x - 120) + math.abs(y - 200);

  -- TwinBee 3: Poko Poko Daimaō  
--  for frame = startFrame, endFrame - 1 do
--    finest("emu.frameadvance();");
--    emu.frameadvance();
--    finest("emu.frameadvance(); exit");
--    
--    local death1 = memory.readbyte(0x014a);
--    if death1 ~= 0 and death1 ~= 128 then
--      info("death1", death1);
--      return -1e4 * frame + 1e6;
--    end
--    
--    local death2 = memory.readbyte(0x014b);
--    if death2 ~= 0 and death2 ~= 128 then
--      info("death2", death2);
--      return -1e4 * frame + 1e6;
--    end
--  end
--
--  local score1 = (memory.readbyte(0x07e4) % 8) * 1
--    + math.floor(memory.readbyte(0x07e4) / 8) * 10
--    + (memory.readbyte(0x07e5) % 8) * 100
--    + math.floor(memory.readbyte(0x07e5) / 8) * 1000
--    + (memory.readbyte(0x07e6) % 8) * 10000
--    + math.floor(memory.readbyte(0x07e6) / 8) * 100000;
--  local score2 = (memory.readbyte(0x07e8) % 8) * 1
--    + math.floor(memory.readbyte(0x07e8) / 8) * 10
--    + (memory.readbyte(0x07e9) % 8) * 100
--    + math.floor(memory.readbyte(0x07e9) / 8) * 1000
--    + (memory.readbyte(0x07ea) % 8) * 10000
--    + math.floor(memory.readbyte(0x07ea) / 8) * 100000;
--    
--  local x1 = memory.readbyte(0x0460);
--  local y1 = memory.readbyte(0x0430);
--  
--  local x2 = memory.readbyte(0x0461);
--  local y2 = memory.readbyte(0x0431);
--  
--  local weapon1 = memory.readbyte(0x0146);
--  local weapon2 = memory.readbyte(0x0147);
--  
--  local dummy1 = memory.readbyte(0x016c);
--  local dummy2 = memory.readbyte(0x016d);
--
--  local speed1 = memory.readbyte(0x054c);
--  local speed2 = memory.readbyte(0x054d);
--  
--  local arm1 = memory.readbyte(0x014c);
--  local arm2 = memory.readbyte(0x014d);
--  
--  return -1e4 * endFrame
--    - score1
--    - score2
--    + math.abs(x1 - 0x60)
--    + math.abs(y1 - 0xb0)
--    + math.abs(x2 - 0xa0)
--    + math.abs(y2 - 0xb0)
--    - 1e6 * weapon1
--    - 1e6 * weapon2
--    - 1e6 * dummy1
--    - 1e6 * dummy2
--    - 1e6 * math.abs(speed1 - 2)
--    - 1e6 * math.abs(speed2 - 2)
--    - 1e6 * arm1
--    - 1e6 * arm2
--    ;
end

--- Applies Simulated Annealing between startFrame (inclusive) and endFrame (eclusive)
-- Pseudocode of the process is below (copied from Wikipedia).
--   s ← s0; e ← E(s)                          // Initial state, energy.               
--   k ← 0                                     // Energy evaluation count.             
--   while k < kmax and e > emin               // While time left & not good enough:   
--     T ← temperature(k/kmax)                 // Temperature calculation.             
--     snew ← neighbour(s)                     // Pick some neighbour.                 
--     enew ← E(snew)                          // Compute its energy.                  
--     if P(e, enew, T) > random() then        // Should we move to it?                
--       s ← snew; e ← enew                    // Yes, change state.                   
--     k ← k + 1                               // One more evaluation done.
-- @param #number startFrame Frame number of the start frame
-- @param #number endFrame Frame number of the end frame
local function anneal(startFrame, endFrame)
  finer("anneal()");

  local timeStart = os.clock();
  local timeEnd = timeStart + TIME_LIMIT_SECS;
  local state = generateInitialState(startFrame, endFrame);
  local energy = calculateEnergy(state)
  local result = copytable(state);
  local minEnergy = energy;
  local counter = 0;
  local timeCurrent = os.clock();
  while timeCurrent < timeEnd do
    local neighborState = generateNeighborState(state);
    local energyNeighbor = calculateEnergy(neighborState);
    local random = math.random();
    local temperature = 1.0 * (timeEnd - timeCurrent) / (timeEnd - timeStart) + 1e-8;
    local probability = calculateProbability(energy, energyNeighbor, temperature);
    if random < probability then
      -- Accept the neighbor state.
      state = neighborState;
      if minEnergy > energyNeighbor then
        info(string.format("minEnergy updated! %.5f -> %.5f", minEnergy, energyNeighbor));
        minEnergy = energyNeighbor;
        result = copytable(state);
      end
      info(string.format("+++ Accepted %.5f -> %.5f : minEnergy=%.5f", energy, energyNeighbor, minEnergy));
      energy = energyNeighbor;
    else
      -- Decline
      info(string.format("--- Declined %.5f -> %.5f : minEnergy=%.5f", energy, energyNeighbor, minEnergy));
    end
    counter = counter + 1;
    timeCurrent = os.clock();
  end
  info(string.format("counter:%d minEnergy:%.5f", counter, minEnergy));
  info();
  return result;
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

--local duration = 60 * 10;
--local inputSequence = generateRandomInputSequence(START_FRAME, START_FRAME + duration);
--setInputSequence(START_FRAME, START_FRAME + duration, inputSequence);
--anneal(START_FRAME, START_FRAME + duration);

--local initialInputSequence = generateRandomInputSequence(initialFrame, initialFrame + SEARCH_WINDOW_SIZE);
--setInputSequence(initialFrame, initialFrame + SEARCH_WINDOW_SIZE, initialInputSequence);
finest("emu.speedmode();");
emu.speedmode("turbo");
emu.speedmode("maximum");

local initialInputSequences = generateRandomInputSequences(START_FRAME, START_FRAME + SEARCH_WINDOW_SIZE);
setInputSequences(START_FRAME, START_FRAME + SEARCH_WINDOW_SIZE, initialInputSequences);

for step = 0, 0xffff do
  local startFrame = START_FRAME + SEARCH_STEP * step;
  local endFrame = startFrame + SEARCH_WINDOW_SIZE;
  info(string.format("step:%d startFrame:%d endFrame:%d", step, startFrame, endFrame));
  local inputSequences = generateRandomInputSequences(endFrame - SEARCH_STEP, endFrame);
  setInputSequences(endFrame - SEARCH_STEP, endFrame, inputSequences);
  local state = anneal(startFrame, endFrame);
  
  setInputSequences(startFrame, endFrame, state.inputSequences)

  -- Playback all the frames to avoid pause.
  finest("taseditor.setplayback(startFrame);");
  taseditor.setplayback(startFrame);
  
  for frame = startFrame, endFrame - 1 do
    finest("emu.frameadvance();");
    emu.frameadvance();
    finest("emu.frameadvance(); exit");
  end
end

taseditor.stopseeking();
