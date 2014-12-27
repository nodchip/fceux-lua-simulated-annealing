local START_FRAME = 196;
local HARDNESS = 1e-0;
local TIME_LIMIT_SECS = 10.0;
local FRAMES_PER_WINDOW = 10;

local MODE_UNKNOWN = 0;
local MODE_CHANGE = 1;

local INVALID = -1;

local JOYPAD_A = 0x01;
local JOYPAD_B = 0x02;
local JOYPAD_SELECT = 0x04;
local JOYPAD_START = 0x08;
local JOYPAD_UP = 0x10;
local JOYPAD_DOWN = 0x20;
local JOYPAD_LEFT = 0x40;
local JOYPAD_RIGHT = 0x80;

local PROBABILITY_A = 0.9;
local PROBABILITY_B = 0.9;
local PROBABILITY_SELECT = 0.0;
local PROBABILITY_START = 0.0;
local PROBABILITY_UP = 0.0;
local PROBABILITY_DOWN = 0.0;
local PROBABILITY_LEFT = 0.0;
local PROBABILITY_RIGHT = 0.9;

local JOYPAD_TO_PROBABILITY = {
  [JOYPAD_A] = PROBABILITY_A,
  [JOYPAD_B] = PROBABILITY_B,
  [JOYPAD_SELECT] = PROBABILITY_SELECT,
  [JOYPAD_START] = PROBABILITY_START,
  [JOYPAD_UP] = PROBABILITY_UP,
  [JOYPAD_DOWN] = PROBABILITY_DOWN,
  [JOYPAD_LEFT] = PROBABILITY_LEFT,
  [JOYPAD_RIGHT] = PROBABILITY_RIGHT,
};

local SEARCH_WINDOW_SIZE = 180;
local SEARCH_STEP = 60;

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
-- Joypad and joypad sequence library.
--------------------------------------------------------------------------------

--- Generates a random joypad (the combination of pushed buttons)
-- @return #number Random joypad. The return value can be passed to taseditor.submitinputchange().
local function generateRandomJoypad()
  finer("generateRandomJoypad()");

  joypad = 0;
  for key, probability in pairs(JOYPAD_TO_PROBABILITY) do
    local r = math.random();
    finest(key, probability, r);
    if r < probability then
      joypad = OR(joypad, key);
    end
  end
  finest(joypad);
  return joypad;
end

--- Generates the sequence of random joypads (the combinations of pushed buttons)
-- @param #number startFrame Frame number of the start frame.
-- @param #number endFrame Frame number of the end frame. The joypad of this frame is not generated.
-- @return #map<#keyvalue,#valuetype> Map from frame numbers to joypads.
local function generateRandomJoypadSequence(startFrame, endFrame)
  finer(string.format("generateRandomJoypadSequence(%d, %d)", startFrame, endFrame));

  local joypadSequence = {};
  for frame = startFrame, endFrame - 1, FRAMES_PER_WINDOW do
    joypadSequence[frame] = generateRandomJoypad();
  end

  return joypadSequence;
end

--- Sets the sequence of joypads (the combinations of pushed buttons) to the TAS Editor
-- @param #number startFrame Frame number of the start frame.
-- @param #number endFrame Frame number of the end frame. The joypad of this frame is not generated.
local function setJoypadSequence(startFrame, endFrame, joypadSequence)
  finer(string.format("setJoypadSequence(%d, %d, ...)", startFrame, endFrame));

  -- Set the playback frame to startFrame
  -- to avoid the "cannot resume non-suspended coroutine" error.
  taseditor.setplayback(0);

  for frame = startFrame, endFrame - 1, FRAMES_PER_WINDOW do
    local joypad = joypadSequence[frame];
    for delta = 0, FRAMES_PER_WINDOW - 1 do
      taseditor.submitinputchange(frame + delta, 1, joypad);
    end
  end

  taseditor.applyinputchanges();
end

--- Gets the sequence of joypads (the combinations of pushed buttons) from the TAS Editor
-- @param #number startFrame Frame number of the start frame.
-- @param #number endFrame Frame number of the end frame. The joypad of this frame is not set.
local function getJoypadSequence(startFrame, endFrame)
  finer("getJoypadSequence()");

  joypadSequence = {};
  for frame = startFrame, endFrame - 1 do
    joypad = taseditor.getinput(frame, 1);
    finest(string.format("frame:%d joypad:%d", frame, joypad));
    if joypad == -1 then
      joypad = 0;
    end
    joypadSequence[frame] = joypad;
  end

  return joypadSequence;
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
-- number of the end frame and the sequence of joypads (the combinations of
-- pushed buttons).
-- @param #number startFrame Frame number of the start frame
-- @param #number endFrame Frame number of the end frame
-- @return #table Initial state
local function generateInitialState(startFrame, endFrame)
  finer("generateInitialState()");

  local joypadSequence = getJoypadSequence(startFrame, endFrame);
  return {
    startFrame = startFrame,
    endFrame = endFrame,
    joypadSequence = joypadSequence;
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
-- There are several pattern how the sequence of joypads are changed.
-- 1. A joypad in the sequence is changed.
-- 2. Two joypads in the sequence are swapped.
-- 3. Three joypads in the sequence are swapped.
-- 4. A joypad is inserted into the sequence.
-- 5. A joypad is removed from the sequence.
-- @param #state state Given state
local function generateNeighborState(state)
  finer("generateNeighborState()");

  local startFrame = state.startFrame;
  local endFrame = state.endFrame;
  local neighborState = nil;
  while true do
    local mode = math.random(5);
    if mode == 1 then
      -- Change a joypad in joypadSequence.
      local frame = getRandomFrame(startFrame, endFrame);
      local joypad = generateRandomJoypad();
      if state.joypadSequence[frame] ~= joypad then
        info(string.format("Change frame:%d %d -> %d", frame, state.joypadSequence[frame], joypad));
        local joypadSequence = copytable(state.joypadSequence);
        joypadSequence[frame] = joypad;
        return {
          startFrame = startFrame,
          endFrame = endFrame,
          joypadSequence = joypadSequence
        };
      end
      
    elseif mode == 2 then
      -- Swap 2 joypads.
      local frame1 = getRandomFrame(startFrame, endFrame);
      local frame2 = getRandomFrame(startFrame, endFrame);
      if state.joypadSequence[frame1] ~= state.joypadSequence[frame2] then
        info(string.format("Swap frame:%d <-> %d", frame1, frame2));
        local joypadSequence = copytable(state.joypadSequence);
        local temp = joypadSequence[frame1];
        joypadSequence[frame1] = joypadSequence[frame2];
        joypadSequence[frame2] = temp;
        return {
          startFrame = startFrame,
          endFrame = endFrame,
          joypadSequence = joypadSequence
        };
      end
      
    elseif mode == 3 then
      -- Swap 3 joypads.
      local frame1 = getRandomFrame(startFrame, endFrame);
      local frame2 = getRandomFrame(startFrame, endFrame);
      local frame3 = getRandomFrame(startFrame, endFrame);
      if state.joypadSequence[frame1] ~= state.joypadSequence[frame2] and
         state.joypadSequence[frame2] ~= state.joypadSequence[frame3] and
         state.joypadSequence[frame3] ~= state.joypadSequence[frame1] then
        info(string.format("Swap frame:%d <-> %d <-> %d", frame1, frame2, frame3));
        local joypadSequence = copytable(state.joypadSequence);
        local temp = joypadSequence[frame1];
        joypadSequence[frame1] = joypadSequence[frame2];
        joypadSequence[frame2] = joypadSequence[frame3];
        joypadSequence[frame3] = temp;
        return {
          startFrame = startFrame,
          endFrame = endFrame,
          joypadSequence = joypadSequence
        };
      end
      
    elseif mode == 4 then
      -- Insert a joypad.
      local insertionFrame = getRandomFrame(startFrame, endFrame);
      local joypad = generateRandomJoypad();
      info(string.format("Insert frame:%d joypad:%d", insertionFrame, joypad));
      local joypadSequence = copytable(state.joypadSequence);
      for frame = endFrame - 1, insertionFrame + 1, -1 do
        joypadSequence[frame] = joypadSequence[frame - 1];
      end
      joypadSequence[insertionFrame] = joypad;
      return {
        startFrame = startFrame,
        endFrame = endFrame,
        joypadSequence = joypadSequence
      };
      
    elseif mode == 5 then
      -- Remove a joypad.
      local removedFrame = getRandomFrame(startFrame, endFrame);
      local joypad = generateRandomJoypad();
      info(string.format("Remove frame:%d joypad:%d", removedFrame, joypad));
      local joypadSequence = copytable(state.joypadSequence);
      for frame = removedFrame, endFrame - 2 do
        joypadSequence[frame] = joypadSequence[frame + 1];
      end
      joypadSequence[endFrame] = joypad;
      return {
        startFrame = startFrame,
        endFrame = endFrame,
        joypadSequence = joypadSequence
      };
    end
  end
end

--- Calculates the energy of a given state.
-- This functions calculates the energy by the following process.
-- 1. Sets the sequence of joypads to the TAS Editor.
-- 2. Sets the playback frame to startFrame.
-- 3. Lets the emulator to emulate from startFrame (inclusive) to endFrame (exlusive).
-- 4. Retrieves the coordinates of the Mario.
-- 5. Returns the x-coordinates of the Mario multiplied by -1.0.
-- Note that the state will be transit to lower energy.
-- @param #number state Given state
local function calculateEnergy(state)
  finer("calculateEnergy()");

  local startFrame = state.startFrame;
  local endFrame = state.endFrame;
  setJoypadSequence(startFrame, endFrame, state.joypadSequence);
  
  finest("taseditor.setplayback(startFrame);");
  taseditor.setplayback(startFrame);
  
  for frame = startFrame, endFrame - 1 do
    finest("emu.frameadvance();");
    emu.frameadvance();
    finest("emu.frameadvance(); exit");
  end
  
  finest("mx");
  local mx = memory.readbyte(0x0086)+(255*memory.readbyte(0x006D));
  local my = memory.readbyte(0x00CE);
  
  return -1.0 * mx;
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
      info(string.format("Accepted %.5f -> %.5f : minEnergy=%.5f", energy, energyNeighbor, minEnergy));
      energy = energyNeighbor;
    else
      -- Decline
      info("Declined");
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
--local joypadSequence = generateRandomJoypadSequence(START_FRAME, START_FRAME + duration);
--setJoypadSequence(START_FRAME, START_FRAME + duration, joypadSequence);
--anneal(START_FRAME, START_FRAME + duration);

--local initialJoypadSequence = generateRandomJoypadSequence(initialFrame, initialFrame + SEARCH_WINDOW_SIZE);
--setJoypadSequence(initialFrame, initialFrame + SEARCH_WINDOW_SIZE, initialJoypadSequence);
finest("emu.speedmode();");
emu.speedmode("turbo");
emu.speedmode("maximum");

local initialJoypadSequence = generateRandomJoypadSequence(START_FRAME, START_FRAME + SEARCH_WINDOW_SIZE);
setJoypadSequence(START_FRAME, START_FRAME + SEARCH_WINDOW_SIZE, initialJoypadSequence);
for step = 0, 0xffff do
  local startFrame = START_FRAME + SEARCH_STEP * step;
  local endFrame = startFrame + SEARCH_WINDOW_SIZE;
  info(string.format("step:%d startFrame:%d endFrame:%d", step, startFrame, endFrame));
  local joypadSequence = generateRandomJoypadSequence(endFrame - SEARCH_STEP, endFrame);
  setJoypadSequence(endFrame - SEARCH_STEP, endFrame, joypadSequence);
  local state = anneal(startFrame, endFrame);
  
  setJoypadSequence(startFrame, endFrame, state.joypadSequence)

  -- Playback all the frames to avoid pause.
  finest("taseditor.setplayback(startFrame);");
  taseditor.setplayback(0);
  
  for frame = 0, endFrame - 1 do
    finest("emu.frameadvance();");
    emu.frameadvance();
    finest("emu.frameadvance(); exit");
  end
end
