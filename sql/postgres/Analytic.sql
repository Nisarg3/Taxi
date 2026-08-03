select 
    count(trip_id) as trip_per_zone,
    dim_location.zone
from fact_trips
left JOIN dim_location
    on fact_trips.pickup_location_id =dim_location.location_id
group BY dim_location.zone
ORDER BY trip_per_zone DESC
LIMIT 10

SELECT EXTRACT(HOUR FROM pickup_time) AS pickup_hour, count(*)
FROM fact_trips 
GROUP BY 1 
ORDER BY COUNT DESC 
limit 10;


SELECT
        sum(fact_trips.fare_amount)/COUNT(fact_trips.fare_amount) as Average_fair,
        dim_location.borough

FROM
        fact_trips
left JOIN dim_location
        on fact_trips.pickup_location_id = dim_location.location_id
GROUP BY dim_location.borough
ORDER BY average_fair

SELECT
        ROUND(100.0 * COUNT(*) FILTER (WHERE tip_amount != 0) / COUNT(*), 2) AS per_tip,
        dim_location.borough
FROM fact_trips
left join dim_location
        on fact_trips.pickup_location_id = dim_location.location_id
group by dim_location.borough


SELECT
        sum(tip_amount) as total_tip,
        dim_payment.payment_description

FROM
        fact_trips
LEFT join dim_payment
        on fact_trips.payment_type = dim_payment.payment_type
group by payment_description
ORDER BY total_tip DESC limit 1;


/*how does the demand differ on the weekdays then on the weekend */

select 
        count(trip_id) filter (where dim_date.is_weekend = false) as weekday_trips,
        count(trip_id) filter (where dim_date.is_weekend = True) as Weekend_trips
        
from fact_trips
left join dim_date
        on fact_trips.pickup_date_key = dim_date.date_key    


select 
        count(trip_id) filter (where dim_date.is_weekend = false) as weekday_trip,
        count(trip_id) filter (where dim_date.is_weekend = True) as weekend_trip,

        extract(hours from pickup_time) as Time_of_day
from fact_trips
left join dim_date
        on fact_trips.pickup_date_key = dim_date.date_key    

GROUP BY extract(hours from pickup_time)                                                                     
ORDER BY Time_of_day


select 
        count(trip_id) filter (where dim_date.is_weekend = false) as weekday_trip,
        count(trip_id) filter (where dim_date.is_weekend = True) as weekend_trip,

        dim_location.zone as zone_name
from 
        fact_trips
left join dim_location
        on fact_trips.pickup_location_id = dim_location.location_id
left join dim_date
         on fact_trips.pickup_date_key = dim_date.date_key    
group by dim_location.zone

select 
        count(trip_id) filter (where dim_date.is_weekend = false) as weekday_trip,
        count(trip_id) filter (where dim_date.is_weekend = True) as weekend_trip,

        dim_location.borough as zone_borough
from 
        fact_trips
left join dim_location
        on fact_trips.pickup_location_id = dim_location.location_id
left join dim_date
         on fact_trips.pickup_date_key = dim_date.date_key    
group by dim_location.borough

/*rank each day on the basis of the total trips*/
with rn_day as (
        select 
                count(trip_id) as total_count,
                dim_date.day as day_of_month
        from 
                fact_trips
        left JOIN dim_date
                on fact_trips.pickup_date_key = dim_date.date_key
        group by dim_date.day 
)

SELECT 
        row_number() OVER (order by total_count DESC) as rank_day,
        day_of_month,
        total_count
from rn_day
limit 10;


/*rollowing 3 day average of the trip */

with rn_day as (
        select 
                count(trip_id) as total_count,
                dim_date.day as day_of_month
        from 
                fact_trips
        left JOIN dim_date
                on fact_trips.pickup_date_key = dim_date.date_key
        group by dim_date.day 
)

SELECT 
        AVG(total_count) OVER (ORDER BY day_of_month rows BETWEEN 2 preceding and current row) as rolling_avg,
        day_of_month,
        total_count
from rn_day



/*unusal demand at the particular hour*/
with number_of_trip as (
        SELECT
                COUNT(trip_id) as number_of_trip,
                extract(hours from pickup_time) as pickup_hour
                
        FROM    
                fact_trips
        GROUP BY extract(hours from pickup_time)
),sd_avg as (

        SELECT
                number_of_trip,
                pickup_hour,
                avg(number_of_trip) over () as avg_trip_cnt,
                STDDEV(number_of_trip) over () as st_trip
        FROM    
                number_of_trip
), z_score as (
        SELECT
                pickup_hour,
                number_of_trip,
                (number_of_trip- avg_trip_cnt) / NULLif(st_trip,0) as z_score
        FROM
                sd_avg
)

SELECT * from z_score
order by abs(z_score) DESC
