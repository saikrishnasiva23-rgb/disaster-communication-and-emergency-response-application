from sklearn.ensemble import RandomForestClassifier
import pandas as pd


# -----------------------------------------
# 1. Training data
# -----------------------------------------

data = {
    "people": [
        1, 1, 2, 2, 3, 4, 5, 6,
        1, 2, 3, 5, 8, 10, 12, 15,
        1, 2, 4, 7, 9, 11, 14, 20
    ],

    "injured": [
        0, 1, 0, 1, 1, 1, 1, 1,
        0, 0, 1, 1, 1, 1, 1, 1,
        0, 1, 1, 1, 1, 1, 1, 1
    ],

    "emergency_type": [
        0, 1, 0, 1, 2, 2, 3, 3,
        0, 1, 2, 3, 3, 4, 4, 4,
        0, 1, 2, 3, 3, 4, 4, 4
    ],

    "priority": [
        "Low", "Medium", "Low", "High",
        "High", "Critical", "Critical", "Critical",
        "Low", "Medium", "High", "Critical",
        "Critical", "Critical", "Critical", "Critical",
        "Low", "Medium", "High", "Critical",
        "Critical", "Critical", "Critical", "Critical"
    ]
}


df = pd.DataFrame(data)


# -----------------------------------------
# 2. Prepare features and target
# -----------------------------------------

X = df[
    [
        "people",
        "injured",
        "emergency_type"
    ]
]

y = df["priority"]


# -----------------------------------------
# 3. Train Random Forest model
# -----------------------------------------

model = RandomForestClassifier(
    n_estimators=100,
    random_state=42
)

model.fit(X, y)


# -----------------------------------------
# 4. Emergency type conversion
# -----------------------------------------

EMERGENCY_TYPES = {
    "Medical Emergency": 0,
    "Injury": 1,
    "Fire Emergency": 2,
    "Flood Emergency": 3,
    "Trapped Person": 4
}


# -----------------------------------------
# 5. Prediction function
# -----------------------------------------

def predict_priority(
    people,
    injured,
    emergency_type
):
    """
    Predict emergency priority using
    the trained Random Forest model.
    """

    emergency_code = EMERGENCY_TYPES.get(
        emergency_type,
        0
    )

    injured_value = 1 if str(injured).lower() == "yes" else 0

    input_data = pd.DataFrame(
        [[
            people,
            injured_value,
            emergency_code
        ]],
        columns=[
            "people",
            "injured",
            "emergency_type"
        ]
    )

    prediction = model.predict(input_data)[0]

    probabilities = model.predict_proba(input_data)[0]

    confidence = max(probabilities) * 100

    return {
        "priority": prediction,
        "confidence": round(confidence, 2)
    }


# -----------------------------------------
# 6. Test the model
# -----------------------------------------

if __name__ == "__main__":

    result = predict_priority(
        people=5,
        injured="Yes",
        emergency_type="Medical Emergency"
    )

    print("AI Priority Result:")
    print(result)