from flask import Flask, jsonify, request
from flask_cors import CORS
import sqlite3
import os

from ai.priority_model import predict_priority


app = Flask(__name__)
CORS(app)

DATABASE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "rescue_requests.db"
)


def init_database():
    connection = sqlite3.connect(DATABASE)
    cursor = connection.cursor()

    cursor.execute("""
        CREATE TABLE IF NOT EXISTS rescue_requests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            emergency_type TEXT NOT NULL,
            number_of_people INTEGER,
            injured TEXT,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            message TEXT,
            status TEXT DEFAULT 'Pending',
            priority_score REAL DEFAULT 0,
            priority_level TEXT DEFAULT 'Low'
        )
    """)

    # Add AI priority columns if the database already existed
    cursor.execute("PRAGMA table_info(rescue_requests)")
    columns = [row[1] for row in cursor.fetchall()]

    if "priority_score" not in columns:
        cursor.execute("""
            ALTER TABLE rescue_requests
            ADD COLUMN priority_score REAL DEFAULT 0
        """)

    if "priority_level" not in columns:
        cursor.execute("""
            ALTER TABLE rescue_requests
            ADD COLUMN priority_level TEXT DEFAULT 'Low'
        """)

    connection.commit()
    connection.close()


@app.route("/")
def home():
    return jsonify({
        "message": "Disaster Communication Backend is running!"
    })


@app.route("/api/rescue-request", methods=["POST"])
def rescue_request():

    data = request.get_json()

    if not data:
        return jsonify({
            "success": False,
            "message": "No data received"
        }), 400

    name = data.get("name")
    emergency_type = data.get("emergencyType")
    number_of_people = data.get("numberOfPeople")
    injured = data.get("injured")
    latitude = data.get("latitude")
    longitude = data.get("longitude")
    message = data.get("message")

    if not name:
        return jsonify({
            "success": False,
            "message": "Name is required"
        }), 400

    if not emergency_type:
        return jsonify({
            "success": False,
            "message": "Emergency type is required"
        }), 400

    if latitude is None or longitude is None:
        return jsonify({
            "success": False,
            "message": "Location is required"
        }), 400

    # -----------------------------------------
    # AI PRIORITY PREDICTION
    # -----------------------------------------

    try:
        people_count = int(number_of_people or 1)

        ai_result = predict_priority(
            people=people_count,
            injured=injured or "No",
            emergency_type=emergency_type
        )

        priority_level = ai_result["priority"]
        priority_score = float(ai_result["confidence"])

    except Exception as e:
        print("AI Priority Error:", e)

        priority_level = "Low"
        priority_score = 0.0

    # -----------------------------------------
    # SAVE REQUEST TO SQLITE
    # -----------------------------------------

    connection = sqlite3.connect(DATABASE)
    cursor = connection.cursor()

    cursor.execute("""
        INSERT INTO rescue_requests
        (
            name,
            emergency_type,
            number_of_people,
            injured,
            latitude,
            longitude,
            message,
            priority_score,
            priority_level
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        name,
        emergency_type,
        number_of_people,
        injured,
        latitude,
        longitude,
        message,
        priority_score,
        priority_level
    ))

    request_id = cursor.lastrowid

    connection.commit()
    connection.close()

    # -----------------------------------------
    # PRINT REQUEST DETAILS
    # -----------------------------------------

    print("\nNEW RESCUE REQUEST SAVED:")
    print("Request ID:", request_id)
    print("Name:", name)
    print("Emergency:", emergency_type)
    print("People:", number_of_people)
    print("Injured:", injured)
    print("Location:", latitude, longitude)
    print("AI Priority:", priority_level)
    print("AI Confidence:", priority_score)

    return jsonify({
        "success": True,
        "message": "Rescue request saved successfully!",
        "requestId": request_id,
        "priority": priority_level,
        "confidence": priority_score
    })


@app.route("/api/rescue-requests", methods=["GET"])
def get_rescue_requests():

    connection = sqlite3.connect(DATABASE)
    connection.row_factory = sqlite3.Row

    cursor = connection.cursor()

    cursor.execute("""
        SELECT *
        FROM rescue_requests
        ORDER BY
            CASE priority_level
                WHEN 'Critical' THEN 1
                WHEN 'High' THEN 2
                WHEN 'Medium' THEN 3
                WHEN 'Low' THEN 4
                ELSE 5
            END,
            id DESC
    """)

    requests_data = cursor.fetchall()

    connection.close()

    requests_list = []

    for row in requests_data:
        requests_list.append(dict(row))

    return jsonify({
        "success": True,
        "requests": requests_list
    })


if __name__ == "__main__":
    init_database()

    app.run(
        host="0.0.0.0",
        port=5000,
        debug=True
    )