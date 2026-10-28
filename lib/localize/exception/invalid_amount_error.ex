defmodule Localize.InvalidAmountError do
  @moduledoc """
  Exception returned when a currency amount names its currency but its
  number cannot be read.

  `Localize.Number.Parser.parse_currency_amount/2` returns it with the
  `:currency` it found, the `:amount` text it could not read as a number,
  and the number parser's own error as `:cause`.

  """

  defexception [:currency, :amount, :cause]

  @impl true
  def exception(bindings) when is_list(bindings) do
    struct!(__MODULE__, bindings)
  end

  @impl true
  def message(%__MODULE__{currency: currency, amount: amount}) do
    Localize.Exception.safe_message(
      "currency",
      "The amount {$amount} of currency {$currency} is not a number.",
      amount: inspect(amount),
      currency: inspect(currency)
    )
  end
end
