import ballerina/io;
import ballerina/workflow;

# Validates an expense claim against the expense policy.
#
# + claim - The submitted claim
# + return - `true` when the claim is claimable, or an error
@workflow:Activity
function validateClaim(ExpenseClaim claim) returns boolean|error {
    return claim.amount > 0d && claim.purpose.trim().length() > 0;
}

# Pays the reimbursement through the mock payment gateway. Payments in USD or
# LKR are rejected — with a Human Review retry policy the failure creates a
# retry review task where a manager can fix the inputs and re-run.
#
# + claimId - The claim being reimbursed
# + amount - Amount to pay
# + currency - Payment currency
# + return - The payment reference, or an error
@workflow:Activity
function makePayment(string claimId, decimal amount, string currency) returns string|error {
    if currency == "USD" || currency == "LKR" {
        return error(string `Payment gateway rejected currency '${currency}' for claim ${claimId}`);
    }
    io:println(string `[payment] Paid ${amount} ${currency} for claim ${claimId}`);
    return string `PAY-${claimId}`;
}

int notifyAttempts = 0;

# Notifies the employee of the outcome. The mock notification service fails on
# every other call — an Auto Retry policy recovers it transparently.
#
# + claimId - The claim identifier
# + message - The notification text
# + return - A delivery reference, or an error
@workflow:Activity
function notifyEmployee(string claimId, string message) returns string|error {
    notifyAttempts += 1;
    if notifyAttempts % 2 == 1 {
        return error("Notification service unavailable (transient)");
    }
    io:println(string `[notification] ${claimId}: ${message}`);
    return string `NOTIF-${claimId}`;
}

# Checks the submitted bills against the claim: at least one bill, and the billed
# total must match the claimed amount.
#
# + claim - The original claim
# + submission - The submitted bills
# + return - `true` when the bills support the claim, or an error
@workflow:Activity
function validateBills(ExpenseClaim claim, BillSubmission submission) returns boolean|error {
    if submission.bills.length() == 0 {
        return false;
    }
    decimal total = 0;
    foreach Bill bill in submission.bills {
        total += bill.amount;
    }
    return total == claim.amount;
}
