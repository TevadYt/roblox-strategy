--!strict
-- Risk dice: each side rolls, both sides sort high to low, and the pairs are
-- compared. The higher die wins each pair and ties go to the defender.

export type Random = (min: number, max: number) -> number

export type Battle = {
	attackRolls: { number },
	defendRolls: { number },
	attackerLosses: number,
	defenderLosses: number,
}

local Dice = {}

local function rollMany(random: Random, count: number): { number }
	local rolls = table.create(count)
	for i = 1, count do
		rolls[i] = random(1, 6)
	end
	table.sort(rolls, function(a, b)
		return a > b
	end)
	return rolls
end

-- Rolls are expected sorted high to low.
function Dice.compare(attackRolls: { number }, defendRolls: { number }): (number, number)
	local attackerLosses, defenderLosses = 0, 0
	for i = 1, math.min(#attackRolls, #defendRolls) do
		if attackRolls[i] > defendRolls[i] then
			defenderLosses += 1
		else
			attackerLosses += 1
		end
	end
	return attackerLosses, defenderLosses
end

function Dice.battle(random: Random, attackDice: number, defendDice: number): Battle
	local attackRolls = rollMany(random, attackDice)
	local defendRolls = rollMany(random, defendDice)
	local attackerLosses, defenderLosses = Dice.compare(attackRolls, defendRolls)
	return {
		attackRolls = attackRolls,
		defendRolls = defendRolls,
		attackerLosses = attackerLosses,
		defenderLosses = defenderLosses,
	}
end

return Dice
