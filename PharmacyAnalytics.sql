DROP SCHEMA IF EXISTS pharmacy_analytics ;

CREATE SCHEMA pharmacy_analytics ;
USE pharmacy_analytics ;

CREATE TABLE evitalrx_clean_master(
Bill_Name INT,
Bill_Date VARCHAR (20),
Item_Name VARCHAR(200),
Category VARCHAR(50),
MRP DECIMAL(10,2),
Unit VARCHAR(50),
Size VARCHAR(50),
Manufacturer VARCHAR(200),
Unit_sold INT,
Stock_on_Hand INT,
Discount_Pct DECIMAL(10,2),
Sell_Amt DECIMAL(10,2),
PTR DECIMAL(10,2),
Net_GST DECIMAL(10,2),
Profit DECIMAL(10,2),
Margin_Pct DECIMAL(10,2)
) ;

-- Creating a staging table to safely test transformations without jeopardizing the master production data.

SELECT *
FROM evitalrx_clean_master;

CREATE TABLE evitalrx_clean_master_dummy
LIKE evitalrx_clean_master;

INSERT evitalrx_clean_master_dummy
SELECT *
FROM evitalrx_clean_master ;

-- Converting DD-MM-YY string to SQL DATE object to enable time-series revenue analysis.

ALTER TABLE evitalrx_clean_master_dummy
ADD COLUMN Temp_date DATE ;

SET SQL_SAFE_UPDATES = 0 ;
SET SQL_SAFE_UPDATES = 1 ;

UPDATE evitalrx_clean_master_dummy
SET Temp_date = STR_TO_DATE(Bill_Date, '%d-%m-%y') ;

ALTER TABLE evitalrx_clean_master_dummy
DROP COLUMN Bill_Date ;

ALTER TABLE evitalrx_clean_master_dummy
RENAME COLUMN Temp_date TO Bill_Date ;

ALTER TABLE evitalrx_clean_master_dummy
MODIFY COLUMN Bill_Date DATE AFTER Bill_Name ;

-- Analyzing monthly PTR to identify the zero-cost inventory transfer anomaly in the early months.

SELECT 
	DATE_FORMAT(Bill_Date, '%Y-%m') AS Sales_Month,
    COUNT(Item_Name) AS Total_Item_Sold,
    SUM(
		CASE
        WHEN PTR = 0.00 THEN 1 ELSE 0 END)
        AS Zero_PTR_Count,
    SUM(Sell_Amt) AS Monthly_Revenue,
    SUM(PTR) AS Total_Recorded_Cost
	FROM evitalrx_clean_master_dummy
    GROUP BY DATE_FORMAT(Bill_Date, '%Y-%m')
    ORDER BY Sales_Month ;

-- Analyzing total revenue and profit margins by product category.
-- Excluding zero-PTR items to prevent artificially inflated 100% profit margins. 

SELECT
	Category,
    COUNT(Bill_Name) AS Total_Transactions,
    SUM(Sell_Amt) AS Gross_Revenue,
    SUM(Sell_Amt - PTR) AS Estimated_Gross_Profit,
    ROUND((SUM(Sell_Amt-PTR)/SUM(Sell_Amt))*100,2)
    AS Avg_Margin_Pct
FROM evitalrx_clean_master_dummy
WHERE PTR > 0.00
GROUP BY Category
ORDER BY Gross_Revenue DESC ;

-- Identifying top 10 most profitable individual items and comparing unit volume vs. net profit.

SELECT
	Item_Name,
    Category,
    SUM(Unit_sold) AS Total_Units_Sold,
    SUM(Sell_Amt) AS Total_Revenue,
    SUM(Sell_Amt-PTR) AS Total_Profit,
	ROUND((SUM(Sell_Amt-PTR)/SUM(Sell_Amt))*100,2)
    AS Margin_Pct
FROM evitalrx_clean_master_dummy
WHERE PTR > 0.00
GROUP BY Item_Name, Category
order by Total_Profit DESC
LIMIT 10 ;

-- Auditing the '-' category anomaly to identify the highest-revenue uncategorized items. 

SELECT
	Item_Name, 
    Manufacturer,
    COUNT(Bill_Name) AS Transaction_Count,
    SUM(Unit_sold) AS Total_Units,
	SUM(Sell_Amt) AS Total_Revenue
FROM evitalrx_clean_master_dummy
WHERE Category = '-'
GROUP BY Item_Name, Manufacturer
ORDER BY Total_Revenue DESC
LIMIT 15
;

SET SQL_SAFE_UPDATES = 0 ;
SET SQL_SAFE_UPDATES = 1 ;

-- Batch 1: Reclassifying the top revenue drivers in the '-' category using verified item & manufacturer patterns.

UPDATE evitalrx_clean_master_dummy
SET Category = CASE 
    -- 1. Veterinary items (Checking both Item_Name and Manufacturer for 'Vet' or 'Tick')
    WHEN Item_Name LIKE '%Veterinary%' OR Item_Name LIKE '%Tick%' OR Manufacturer LIKE '%Vet%' THEN 'Pet care'
    
    -- 2. Pregnancy Test Kits -> Medical devices
    WHEN Item_Name LIKE '%Prega%' OR Item_Name LIKE '%Pregpass%' OR Item_Name LIKE '%Pregnancy%' THEN 'Medical devices'
    
    -- 3. Condoms -> Personal hygiene
    WHEN Item_Name LIKE '%Condom%' OR Item_Name LIKE '%Manforce%' THEN 'Personal hygiene'
    
    -- 4. Perfume Sprays -> Cosmetic
    WHEN Item_Name LIKE '%Perfume%' THEN 'Cosmetic'
    
    -- 5. Baby Diapers -> Baby care
    WHEN Item_Name LIKE '%Diaper%' THEN 'Baby care'
    
    -- 6. Allopathic Tablets & Inhalers -> Drug
    WHEN Item_Name LIKE '%Tablet%' OR Item_Name LIKE '%Inhaler%' THEN 'Drug'
    
    -- 7. Vaporizing Rubs -> OTC
    WHEN Item_Name LIKE '%Vaporizing Rub%' OR Item_Name LIKE '%Respirub%' THEN 'OTC'
    
    ELSE Category
END
WHERE Category = '-'
;

-- Batch 2(Final Cleanup): Reclassifying remaining patterns and converting any residual '-' rows to 'Uncatogrized OTC'. 

UPDATE evitalrx_clean_master_dummy
SET Category = CASE
	-- 1. Catch the cattle feed gel('Bbc Animal Nutrition') first 
    WHEN Manufacturer LIKE '%Animal%' THEN 'Pet Care'
    
    -- 2. Body sprays, talcs and cosmetics manufacturers
    WHEN Item_Name LIKE '%Body Sprays%' OR Item_Name LIKE '%Tals%' OR Manufacturer LIKE '%Cosmetics%' THEN 'Cosmetics'
    
    -- 3. Toothpaste, shampoos, and soap bars
    WHEN Item_Name LIKE '%Toothpaste%' OR Item_Name LIKE '%Shampoo%' OR Item_Name LIKE '%BARS%' THEN 'Personal Hygiene'
    
    -- 4. Ayurvedic oils
    WHEN Item_Name LIKE '%Sarsav Oil%' OR Item_Name LIKE '%Ayupaas%' THEN 'Ayurvedic'
    
    -- 5. Medicated creams, capsules, syrups, drops and pain sprays
    WHEN Item_Name LIKE '%creaam%' OR Item_Name LIKE '%capsules%' OR Item_Name LIKE '%syrup%' OR Item_Name LIKE '%Drops%' OR Item_Name LIKE '%Fast Sprays%'
    THEN 'Drug'

	-- 6. Final Fallback: Elimanate the '-' symbol completely
    ELSE 'Uncategorized OTC'
END
WHERE Category ='-' ;

-- Fixing/Renamig the spelling typo in the column name. 

UPDATE evitalrx_clean_master_dummy
SET Category = 'Uncategorized OTC'
WHERE Category = 'Uncategarized OTC';

UPDATE evitalrx_clean_master_dummy
SET Category = 'Cosmetic'
WHERE Category = 'Cosmetics' ;

ALTER TABLE evitalrx_clean_master_dummy
RENAME COLUMN Manufacturere TO Manufacturer ;

ALTER TABLE evitalrx_clean_master_dummy
RENAME COLUMN Bill_Name TO Bill_No ;

-- Using a CTE and RANK()Window Function to identify the Top 3 most profitable items within EACH catagory. 

WITH Catagory_Item_Profits as(
 SELECT
	Category,
	Item_Name,
    SUM(Unit_sold) AS Total_Units,
    SUM(Sell_Amt) AS Total_Revenue,
    SUM(Sell_Amt - PTR) AS Total_Profit,
    RANK() OVER(
			PARTITION BY Category
            ORDER BY  SUM(Sell_Amt - PTR) DESC
	) AS Profit_Rank
 FROM evitalrx_clean_master_dummy
 WHERE PTR > 0.00
 GROUP BY Category, Item_Name
)
SELECT
 Category,
 Profit_Rank,
 Item_Name,
 Total_Units,
 Total_Revenue, 
 Total_Profit
FROM Catagory_Item_Profits
WHERE Profit_Rank <= 3
ORDER BY Category, Profit_Rank
;

-- Calculating Month-over-Month (MoM) Revenue Growth using a CTE and the LAG() Window Function.
-- Excluding '2026-11' because it only contains partial month-to-date records.

WITH Monthly_Sales AS (
    SELECT 
        DATE_FORMAT(Bill_Date, '%Y-%m') AS Sales_Month,
        SUM(Sell_Amt) AS Monthly_Revenue
    FROM evitalrx_clean_master_dummy
    WHERE DATE_FORMAT(Bill_Date, '%Y-%m') != '2026-11'
    GROUP BY DATE_FORMAT(Bill_Date, '%Y-%m')
)
SELECT 
    Sales_Month,
    Monthly_Revenue,
    LAG(Monthly_Revenue) OVER (ORDER BY Sales_Month) AS Previous_Month_Revenue,
    ROUND(
        ((Monthly_Revenue - LAG(Monthly_Revenue) OVER (ORDER BY Sales_Month)) 
        / LAG(Monthly_Revenue) OVER (ORDER BY Sales_Month)) * 100, 
    2) AS MoM_Growth_Pct
FROM Monthly_Sales
ORDER BY Sales_Month;

-- Creating a Dimension Table to store business segments and target profit margins by category.

CREATE TABLE dim_category_benchmarks (
    Category VARCHAR(50) PRIMARY KEY,
    Business_Segment VARCHAR(30),
    Target_Margin_Pct DECIMAL(5,2)
);

INSERT INTO dim_category_benchmarks (Category, Business_Segment, Target_Margin_Pct) VALUES
('Drug', 'Core Pharma', 55.00),
('Generic', 'Core Pharma', 70.00),
('Surgical', 'Core Pharma', 35.00),
('Medical devices', 'Core Pharma', 60.00),
('Ayurvedic', 'Wellness', 35.00),
('Nutraceuticals', 'Wellness', 30.00),
('OTC', 'Wellnesdim_category_benchmarksCategorys', 35.00),
('Personal hygiene', 'FMCG', 30.00),
('Cosmetic', 'FMCG', 30.00),
('Baby care', 'FMCG', 45.00),
('Household essentials', 'FMCG', 25.00),
('Pet care', 'Specialty', 45.00);

-- INNER JOIN: Comparing actual catagory profit margins against target benchmarks by business segment. 

SELECT
 b.Business_Segment,
 s.Category,
 SUM(s.Sell_Amt) AS Gross_Revenue,
 ROUND((SUM(s.Sell_Amt-s.PTR)/SUM(s.Sell_Amt))*100, 2) AS Actual_Margin_Pct,
 b.Target_Margin_Pct,
  CASE
    WHEN ROUND((SUM(s.Sell_Amt-s.PTR)/SUM(s.Sell_Amt))*100,2)>=b.Target_Margin_Pct
    THEN 'Above Target'
	ELSE 'Below Taget'
  END AS Performance_Status
FROM evitalrx_clean_master_dummy s 
INNER JOIN dim_category_benchmarks b 
  ON s.Category = b.Category 
WHERE s.PTR > 0.00
GROUP BY  b.Business_Segment, s.Category,  b.Target_Margin_Pct
ORDER BY  b.Business_Segment, Actual_Margin_Pct
		DESC ;
 
 -- LEFT JOIN :Auditing sales categories that are missing from the official benchmark table.
 
 SELECT
  s.Category,
  COUNT(s.Bill_No) AS Unmappeed_Transcations,
  SUM(s.Sell_Amt) AS Unmapped_Revenue
FROM evitalrx_clean_master_dummy s 
LEFT JOIN dim_category_benchmarks b
	ON s.Category = b.Category
WHERE b.Category IS NULL 
GROUP BY s.Category ;
 

 
 
 
 
 
 
 
 
 
 
 
 
 



























